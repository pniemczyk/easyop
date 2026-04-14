module Admin
  class OperationLogsController < BaseController
    def index
      @logs = OperationLog.recent
      @logs = @logs.where(success: params[:success] == "true") if params[:success].present?
      @logs = @logs.for_operation(params[:operation]) if params[:operation].present?
      @logs = @logs.order_related if params[:category] == "orders"
      @logs = @logs.limit(100)
      @operations = OperationLog.distinct.pluck(:operation_name).sort
    end

    # Shows the full execution tree for the given root log (identified by id).
    # All operations that share the same root_reference_id are displayed oldest-first
    # so the call tree is readable top-to-bottom.
    def show
      @root_log   = OperationLog.find(params[:id])
      @tree_id    = @root_log.root_reference_id || @root_log.reference_id
      @tree_logs  = OperationLog.for_tree(@tree_id)
    end
  end
end
