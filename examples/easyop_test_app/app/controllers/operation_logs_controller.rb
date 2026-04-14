class OperationLogsController < ApplicationController
  before_action :require_login

  def index
    @logs = OperationLog.recent.limit(100)
  end

  def show
    @root_log  = OperationLog.find(params[:id])
    @tree_id   = @root_log.root_reference_id || @root_log.reference_id
    @tree_logs = OperationLog.for_tree(@tree_id)
  end
end
