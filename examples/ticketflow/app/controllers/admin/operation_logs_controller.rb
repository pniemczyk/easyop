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
  end
end
