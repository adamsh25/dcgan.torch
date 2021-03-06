require 'torch'
require 'nn'
require 'optim'
require 'io'
require 'os'

opt = {
   dataset = 'folder',       -- imagenet / lsun / folder
   batchSize = 64,
   loadSize = 129,
   fineSize = 128,
   nz = 100,               -- #  of dim for Z
   ngf = 150,               -- #  of gen filters in first conv layer
   ndf = 50,               -- #  of discrim filters in first conv layer
   nThreads = 4,           -- #  of data loading threads to use
   niter = 100,             -- #  of iter at starting learning rate
   lr = 0.0002,            -- initial learning rate for adam
   beta1 = 0.5,            -- momentum term of adam
   ntrain = math.huge,     -- #  of examples per epoch. math.huge for full dataset
   display = 0,            -- display samples while training. 0 = false
   display_id = 10,        -- display window id.
   gpu = 0,                -- gpu = 0 is CPU mode. gpu=X is GPU mode on GPU X
   name = 'experiment4',
   noise = 'normal',       -- uniform / normal
   epoch = 1,
   continue=0,
   epoch_save_modulo = 2;
}

-- one-line argument parser. parses enviroment variables to override the defaults
for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
print(opt)

if opt.gpu > 0 then
	print('OPT using GPU')
	require 'cunn'
	require 'cudnn'
end

if opt.display == 0 then opt.display = false end

opt.manualSeed = torch.random(1, 10000) -- fix seed
print("Random Seed: " .. opt.manualSeed)
torch.manualSeed(opt.manualSeed)
torch.setnumthreads(1)
torch.setdefaulttensortype('torch.FloatTensor')

-- create data loader
local DataLoader = paths.dofile('data/data.lua')
local data = DataLoader.new(opt.nThreads, opt.dataset, opt)
print("Dataset: " .. opt.dataset, " Size: ", data:size())
----------------------------------------------------------------------------
local function weights_init(m)
   local name = torch.type(m)
   if name:find('Convolution') then
      m.weight:normal(0.0, 0.02)
      m:noBias()
   elseif name:find('BatchNormalization') then
      if m.weight then m.weight:normal(1.0, 0.02) end
      if m.bias then m.bias:fill(0) end
   end
end

local nc = 3
local nz = opt.nz
local ndf = opt.ndf
local ngf = opt.ngf
local real_label = 1
local fake_label = 0

local epoch_save_modulo = opt.epoch_save_modulo
print("modulo value: ", opt.epoch_save_modulo);

local SpatialBatchNormalization = nn.SpatialBatchNormalization
local SpatialConvolution = nn.SpatialConvolution
local SpatialFullConvolution = nn.SpatialFullConvolution


local criterion = nn.BCECriterion()
---------------------------------------------------------------------------
optimStateG = {
   learningRate = opt.lr,
   beta1 = opt.beta1,
}
optimStateD = {
   learningRate = opt.lr,
   beta1 = opt.beta1,
}
----------------------------------------------------------------------------
local input = torch.Tensor(opt.batchSize, 3, opt.fineSize, opt.fineSize)
local noise = torch.Tensor(opt.batchSize, nz, 1, 1)
local label = torch.Tensor(opt.batchSize)
local errD, errG
local epoch_tm = torch.Timer()
local tm = torch.Timer()
local data_tm = torch.Timer()

if opt.continue == 1 then
   netD = torch.load('checkpoints/' .. opt.name .. '_' .. opt.epoch .. '_net_D.t7')
   netG = torch.load('checkpoints/' .. opt.name .. '_' .. opt.epoch .. '_net_G.t7')
else
	-- init netD ---------------------------------------------------
	netD = nn.Sequential()
	-- input is (nc) x 128 x 128
	netD:add(SpatialConvolution(nc, ndf, 4, 4, 2, 2, 1, 1))
	netD:add(nn.LeakyReLU(0.2, true))
	-- state size: (ndf) x 64 x 64
	netD:add(SpatialConvolution(ndf, ndf * 2, 4, 4, 2, 2, 1, 1))
	netD:add(SpatialBatchNormalization(ndf * 2)):add(nn.LeakyReLU(0.2, true))
	-- state size: (ndf*2) x 32 x 32
	netD:add(SpatialConvolution(ndf * 2, ndf * 4, 4, 4, 2, 2, 1, 1))
	netD:add(SpatialBatchNormalization(ndf * 4)):add(nn.LeakyReLU(0.2, true))
	-- state size: (ndf*4) x 16 x 16
	netD:add(SpatialConvolution(ndf * 4, ndf * 8, 4, 4, 2, 2, 1, 1))
	netD:add(SpatialBatchNormalization(ndf * 8)):add(nn.LeakyReLU(0.2, true))
	-- state size: (ndf*8) x 8 x 8
	netD:add(SpatialConvolution(ndf * 8, ndf * 16, 4, 4, 2, 2, 1, 1))
	netD:add(SpatialBatchNormalization(ndf * 16)):add(nn.LeakyReLU(0.2, true))
	-- state size: (ndf*16) x 4 x 4
	netD:add(SpatialConvolution(ndf * 16, 1, 4, 4))
	netD:add(nn.Sigmoid())
	-- state size: 1 x 1 x 1
	netD:add(nn.View(1):setNumInputDims(3))
	-- state size: 1
	netD:apply(weights_init)
	
	
	-- init netG ---------------------------------------------------
	
	
	netG = nn.Sequential()
	-- input is Z, going into a convolution
	netG:add(SpatialFullConvolution(nz, ngf * 16, 4, 4))
	netG:add(SpatialBatchNormalization(ngf * 16)):add(nn.ReLU(true))
	-- state size: (ngf*16) x 4 x 4
	netG:add(SpatialFullConvolution(ngf * 16, ngf * 8, 4, 4, 2, 2, 1, 1))
	netG:add(SpatialBatchNormalization(ngf * 8)):add(nn.ReLU(true))
	-- state size: (ngf*8) x 8 x 8
	netG:add(SpatialFullConvolution(ngf * 8, ngf * 4, 4, 4, 2, 2, 1, 1))
	netG:add(SpatialBatchNormalization(ngf * 4)):add(nn.ReLU(true))
	-- state size: (ngf*4) x 16 x 16
	netG:add(SpatialFullConvolution(ngf * 4, ngf * 2, 4, 4, 2, 2, 1, 1))
	netG:add(SpatialBatchNormalization(ngf * 2)):add(nn.ReLU(true))
	-- state size: (ngf * 2) x 32 x 32
	netG:add(SpatialFullConvolution(ngf * 2, ngf, 4, 4, 2, 2, 1, 1))
	netG:add(SpatialBatchNormalization(ngf)):add(nn.ReLU(true))
	-- state size: (ngf) x 64 x 64
	netG:add(SpatialFullConvolution(ngf, nc, 4, 4, 2, 2, 1, 1))
	netG:add(nn.Tanh())
	-- state size: (nc) x 128 x 128
	netG:apply(weights_init)

end

----------------------------------------------------------------------------
if opt.gpu > 0 then
	require 'cunn'
      	cutorch.setDevice(opt.gpu)
   	input = input:cuda();  noise = noise:cuda();  label = label:cuda()
       	print('using GPU')
        if pcall(require, 'cudnn') then
		require 'cudnn'
		print('using GPU with cudnn')
	        cudnn.benchmark = true
	      	cudnn.convert(netG, cudnn)
            	cudnn.convert(netD, cudnn)
		print('converted to cudnn')
	end
        netD:cuda();           netG:cuda();           criterion:cuda()
end

local parametersD, gradParametersD = netD:getParameters()
local parametersG, gradParametersG = netG:getParameters()

if opt.display then disp = require 'display' end

noise_vis = noise:clone()
if opt.noise == 'uniform' then
    noise_vis:uniform(-1, 1)
elseif opt.noise == 'normal' then
    noise_vis:normal(0, 1)
end

-- create closure to evaluate f(X) and df/dX of discriminator
local fDx = function(x)
   gradParametersD:zero()

   -- train with real
   data_tm:reset(); data_tm:resume()
   local real = data:getBatch()
   data_tm:stop()
   input:copy(real)
   label:fill(real_label)

   local output = netD:forward(input)
   local errD_real = criterion:forward(output, label)
   local df_do = criterion:backward(output, label)
   netD:backward(input, df_do)

   -- train with fake
   if opt.noise == 'uniform' then -- regenerate random noise
       noise:uniform(-1, 1)
   elseif opt.noise == 'normal' then
       noise:normal(0, 1)
   end
   local fake = netG:forward(noise)
   input:copy(fake)
   label:fill(fake_label)

   local output = netD:forward(input)
   local errD_fake = criterion:forward(output, label)
   local df_do = criterion:backward(output, label)
   netD:backward(input, df_do)

   errD = errD_real + errD_fake

   return errD, gradParametersD
end

-- create closure to evaluate f(X) and df/dX of generator
local fGx = function(x)
   gradParametersG:zero()

   --[[ the three lines below were already executed in fDx, so save computation
   noise:uniform(-1, 1) -- regenerate random noise
   local fake = netG:forward(noise)
   input:copy(fake) ]]--
   label:fill(real_label) -- fake labels are real for generator cost

   local output = netD.output -- netD:forward(input) was already executed in fDx, so save computation
   errG = criterion:forward(output, label)
   local df_do = criterion:backward(output, label)
   local df_dg = netD:updateGradInput(input, df_do)

   netG:backward(noise, df_dg)
   return errG, gradParametersG
end


local coro = function(opt, epoch)
	  os.execute('display=0 gpu=' .. opt.gpu .. ' name=' .. opt.name .. ' batchSize=1 imsize=20 epoch=' .. epoch .. ' th generate.lua')
	  --local file = assert(io.popen('display=0 gpu=0 name=' .. opt.name .. ' batchSize=1 imsize=20 epoch=' .. epoch .. ' th generate.lua', 'r'))
	  --local output = file:read('*all')
	  --file:close()
	  --print(output) -- > Prints the output of the command.
	  print('Done creating image for epoch ' .. epoch)
	end

-- train
for epoch = opt.epoch, opt.niter do
   epoch_tm:reset()
   local counter = 0
   for i = 1, math.min(data:size(), opt.ntrain), opt.batchSize do
      tm:reset()
      -- (1) Update D network: maximize log(D(x)) + log(1 - D(G(z)))
      optim.adam(fDx, parametersD, optimStateD)

      -- (2) Update G network: maximize log(D(G(z)))
      optim.adam(fGx, parametersG, optimStateG)

      -- display
      counter = counter + 1
      if counter % 10 == 0 and opt.display then
          local fake = netG:forward(noise_vis)
          local real = data:getBatch()
          disp.image(fake, {win=opt.display_id, title=opt.name})
          disp.image(real, {win=opt.display_id * 3, title=opt.name})
      end

      -- logging
      if ((i-1) / opt.batchSize) % 1 == 0 then
         print(('Epoch: [%d][%8d / %8d]\t Time: %.3f  DataTime: %.3f  '
                   .. '  Err_G: %.4f  Err_D: %.4f'):format(
                 epoch, ((i-1) / opt.batchSize),
                 math.floor(math.min(data:size(), opt.ntrain) / opt.batchSize),
                 tm:time().real, data_tm:time().real,
                 errG and errG or -1, errD and errD or -1))
      end
   end
   paths.mkdir('checkpoints')
   parametersD, gradParametersD = nil, nil -- nil them to avoid spiking memory
   parametersG, gradParametersG = nil, nil
   if epoch % epoch_save_modulo == 0 then -- allows to pass in modulo value to only save checkpoints at certain intervals
      torch.save('checkpoints/' .. opt.name .. '_' .. epoch .. '_net_G.t7', netG:clearState())
      torch.save('checkpoints/' .. opt.name .. '_' .. epoch .. '_net_D.t7', netD:clearState())
      coro(opt, epoch)
    end
      parametersD, gradParametersD = netD:getParameters() -- reflatten the params and get them
      parametersG, gradParametersG = netG:getParameters()
      print(('End of epoch %d / %d \t Time Taken: %.3f'):format(
               epoch, opt.niter, epoch_tm:time().real))
end
