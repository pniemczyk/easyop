class EasyFlowRunStep < ApplicationRecord
  include Easyop::PersistentFlow::FlowRunStepModel

  belongs_to :flow_run, class_name: 'EasyFlowRun'
end
