class EasyFlowRun < ApplicationRecord
  include Easyop::PersistentFlow::FlowRunModel

  has_many :easy_flow_run_steps, foreign_key: :flow_run_id, dependent: :destroy
end
