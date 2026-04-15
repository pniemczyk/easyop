class AddExecutionIndexToOperationLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :operation_logs, :execution_index, :integer

    # Composite index: find all siblings of a given parent in call order.
    add_index :operation_logs, [:parent_reference_id, :execution_index],
              name: 'index_operation_logs_on_parent_ref_and_exec_index'
  end
end
