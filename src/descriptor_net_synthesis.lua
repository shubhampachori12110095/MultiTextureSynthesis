require 'src/texture_loss'
require 'src/content_loss'
require 'src/tv_loss'

function nop()
  -- nop.  not needed by our net
end

function create_descriptor_net(output_G, texture_image)
   
  local cnn = torch.load(params.loss_model):cuda()

  local texture_layers = params.texture_layers:split(",")
  local diversity_layers = params.diversity_layers:split(",") 

  -- inser texture loss module
  local texture_losses, diversity_losses = {}, {}
  local next_texture_idx, next_diversity_idx = 1, 1
  local net = nn.Sequential()

  --add tv_loss
  if params.tv_weight > 0 then
    local tv_mod = nn.TVLoss(params.tv_weight):cuda()
    net:add(tv_mod)
  end 

  for i = 1, #cnn do
    if next_texture_idx <= #texture_layers then
      local layer = cnn:get(i)
      local layer_type = torch.type(layer)
      
      if layer_type == 'nn.SpatialConvolution' or layer_type == 'nn.SpatialConvolutionMM' or layer_type == 'cudnn.SpatialConvolution' then
        layer.accGradParameters = nop
      end
  
      net:add(layer)
   
      ---------------------------------
      -- Texture loss
      ---------------------------------
      if params.texture_weight ~= 0 and i == tonumber(texture_layers[next_texture_idx]) then
        local gram = GramMatrix():cuda()

        ---------
        local target = nil
        local target_features = net:forward(texture_image):clone()     
				                
	    local target_features_resize = nn.View(-1):cuda():setNumInputDims(2):forward(target_features[1]):t()
				   
	    local mean = torch.mean(target_features_resize, 1)
	    local target_features_resize_subtract_mean = target_features_resize - mean:expandAs(target_features_resize)
				      
		target_features_resize_subtract_mean = target_features_resize_subtract_mean:t()
				      

		local target_t = gram:forward(target_features_resize_subtract_mean):clone()
	    target_t:div(target_features[1]:nElement())
	    target = target_t   

        ----------
        local norm = params.normalize_gradients
        local loss_module = nn.TextureLoss(params.texture_weight, target, norm):cuda()
        
        net:add(loss_module)
        table.insert(texture_losses, loss_module)
        next_texture_idx = next_texture_idx + 1
      end


      ---------------------------------
      -- Diveristy loss
      ---------------------------------
      if params.diversity_weight ~= 0 and i == tonumber(diversity_layers[next_diversity_idx]) then

        local sg = output_G:size()
        local output_G_reorder = torch.Tensor(sg[1], sg[2], sg[3], sg[4]):cuda()
        local index = torch.randperm(params.batch_size)

        while reorder(index) do 
           index = torch.randperm(params.batch_size)
        end

        for i=1, params.batch_size do
           output_G_reorder[i] = output_G[index[i]]
        end

        local target = net:forward(output_G_reorder):clone()

        local norm = false
        local loss_module = nn.ContentLoss(params.diversity_weight, target, norm):cuda()

        net:add(loss_module)
        table.insert(diversity_losses, loss_module)
        next_diversity_idx = next_diversity_idx + 1
      end

    end
  end

  net:add(nn.DummyGradOutput())

  -- We don't need the base CNN anymore, so clean it up to save memory.
  cnn = nil
  for i=1,#net.modules do
    local module = net.modules[i]
    if torch.type(module) == 'nn.SpatialConvolutionMM' or torch.type(module) == 'nn.SpatialConvolution' or torch.type(module) == 'cudnn.SpatialConvolution' then
        module.gradWeight = nil
        module.gradBias = nil
    end
  end
  collectgarbage()
      
  return net, texture_losses, diversity_losses
end

function reorder(array)

   for i=1, params.batch_size do
      if array[i] == i then
        return true
      end
   end

   return false
end
