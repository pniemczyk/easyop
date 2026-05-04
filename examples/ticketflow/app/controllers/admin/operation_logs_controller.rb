module Admin
  class OperationLogsController < BaseController
    def index
      base = OperationLog.recent
      base = base.where(success: params[:success] == "true") if params[:success].present?
      base = base.for_operation(params[:operation]) if params[:operation].present?
      base = base.order_related if params[:category] == "orders"

      # Without an explicit operation filter, scope to root-level logs only so
      # async children don't appear as orphan rows in the chronological list.
      base = base.where(parent_reference_id: nil) unless params[:operation].present?

      root_logs = base.limit(100).to_a
      @logs     = root_logs
      @operations = OperationLog.distinct.pluck(:operation_name).sort

      # Expand each anchor log to its full execution tree.
      tree_ids = root_logs.map(&:root_reference_id).compact.uniq
      if tree_ids.any?
        all_in_trees = OperationLog.where(root_reference_id: tree_ids).order(:performed_at).to_a
        by_tree      = all_in_trees.group_by(&:root_reference_id)
        @tree_groups = root_logs.map { |log| [ log, by_tree.fetch(log.root_reference_id, [ log ]) ] }
      end
    end

    # Shows the full execution tree for the given root log (identified by id).
    # All operations that share the same root_reference_id are displayed oldest-first
    # so the call tree is readable top-to-bottom.
    def show
      @root_log    = OperationLog.find(params[:id])
      @tree_id     = @root_log.root_reference_id || @root_log.reference_id
      @tree_logs   = OperationLog.for_tree(@tree_id)
      # Auto-refresh if the root ran within the last 5 minutes and the tree has
      # only one node — async children may not have fired yet.
      @auto_refresh = @tree_logs.size <= 1 &&
                      @root_log.performed_at > 5.minutes.ago
    end
  end
end
