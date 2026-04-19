class OperationLogsController < ApplicationController
  before_action :require_login

  def index
    @logs = OperationLog.recent

    if params[:operation].present?
      @logs = @logs.for_operation(params[:operation])
      @filter_operation = params[:operation]
    end

    case params[:status]
    when "success" then @logs = @logs.successes
    when "failed"  then @logs = @logs.failures
    end

    @filter_status = params[:status]

    # Stats for the header bar
    base = OperationLog.all
    @stats = {
      total:        base.count,
      succeeded:    base.successes.count,
      failed:       base.failures.count,
      encrypted:    base.encrypted.count,
      avg_duration: base.where.not(duration_ms: nil).average(:duration_ms)&.round(1)
    }

    # Distinct operation names for the filter dropdown
    @operation_names = OperationLog.distinct.pluck(:operation_name).compact.sort

    @logs = @logs.limit(200)
  end

  def show
    @root_log  = OperationLog.find(params[:id])
    @tree_id   = @root_log.root_reference_id || @root_log.reference_id
    @tree_logs = OperationLog.for_tree(@tree_id)
  end
end
