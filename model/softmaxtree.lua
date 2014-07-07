------------------------------------------------------------------------
--[[ SoftmaxTree ]]--
-- A hierarchy of softmaxes.
-- Used for computing the likelihood of a leaf class.
-- Use with TreeNLL Loss.
-- Requires a tensor mapping parent_ids to child_ids. 
-- Root_id defaults to 1
------------------------------------------------------------------------
local SoftmaxTree, parent = torch.class("dp.SoftmaxTree", "dp.Layer")
SoftmaxTree.isSoftmaxTree = true

function SoftmaxTree:__init(config)
   assert(type(config) == 'table', "Constructor requires key-value arguments")
   local args, input_size, hierarchy, root_id, typename, maxOutNorm 
      = xlua.unpack(
      {config},
      'SoftmaxTree', 
      'A hierarchy of softmaxes',
      {arg='input_size', type='number', req=true,
       help='Number of input neurons'},
      {arg='hierarchy', type='table', req=true,
       help='A table mapping parent_ids to a tensor of child_ids'},
      {arg='root_id', type='number | string', default=1,
       help='id of the root of the tree.'},
      {arg='typename', type='string', default='softmaxtree', 
       help='identifies Model type in reports.'},
      {arg='maxOutNorm', type='number', default=1,
       help='max norm of output neuron weights. '..
       'Overrides MaxNorm visitor'}
   )
   self._input_size = input_size
   require 'nnx'
   self._module = nn.SoftMaxTree(
      self._input_size, hierarchy, root_id, maxOutNorm
   )
   config.typename = typename
   config.output = dp.DataView()
   config.input_view = 'bf'
   config.output_view = 'b'
   config.tags = config.tags or {}
   config.tags['no-maxnorm'] = true
   parent.__init(self, config)
   self._target_type = 'torch.IntTensor'
end

-- requires targets be in carry
function SoftmaxTree:_forward(carry)
   local activation = self:inputAct()
   if self._dropout then
      -- dropout has a different behavior during evaluation vs training
      self._dropout.train = (not carry.evaluate)
      activation = self._dropout:forward(activation)
      self.mvstate.dropoutAct = activation
   end
   assert(carry.targets and carry.targets.isClassView,
      "carry.targets should refer to a ClassView of targets")
   local targets = carry.targets:forward('b', self._target_type)
   -- outputs a column vector of likelihoods of targets
   activation = self._module:forward{activation, targets}
   self:outputAct(activation)
   return carry
end

function SoftmaxTree:_backward(carry)
   local scale = carry.scale
   self._report.scale = scale
   local input_act = self.mvstate.dropoutAct or self:inputAct()
   local output_grad = self:outputGrad()
   assert(carry.targets and carry.targets.isClassView,
      "carry.targets should refer to a ClassView of targets")
   local targets = carry.targets:forward('b', self._target_type)
   output_grad = self._module:backward({input_act, targets}, output_grad, scale)
   if self._dropout then
      self.mvstate.dropoutGrad = output_grad
      input_act = self:inputAct()
      output_grad = self._dropout:backward(input_act, output_grad, scale)
   end
   self:inputGrad(output_grad)
   return carry
end

function SoftmaxTree:_type(type)
   self._input_type = type
   self._output_type = type
   if self._dropout then
      self._dropout:type(type)
   end
   if type == 'torch.CudaTensor' then
      require 'cunnx'
      self._target_type = 'torch.CudaTensor'
   else
      self._target_type = 'torch.IntTensor'
   end
   self._module:type(type)
   return self
end

function SoftmaxTree:reset()
   self._module:reset()
   if self._sparse_init then
      self._sparseReset(self._module.weight)
   end
end

function SoftmaxTree:zeroGradParameters()
   self._module:zeroGradParameters(true)
end

-- if after feedforward, returns active parameters 
-- else returns all parameters
function SoftmaxTree:parameters()
   return self._module:parameters(true)
end

function SoftmaxTree:sharedClone()
   local clone = torch.protoClone(self, {
      input_size=self._input_size, hierarchy={[1]=torch.IntTensor{1,2}},
      root_id=1, sparse_init=self._sparse_init,
      dropout=self._dropout and self._dropout:clone(),
      typename=self._typename, 
      input_type=self._input_type, output_type=self._output_type,
      module_type=self._module_type, mvstate=self.mvstate
   })
   clone._target_type = self._target_type
   clone._module = self._module:sharedClone()
   return clone
end

function SoftmaxTree:updateParameters(lr)
   self._module:updateParameters(lr, true)
end

function SoftmaxTree:maxNorm()
   error"NotImplemented"
end

