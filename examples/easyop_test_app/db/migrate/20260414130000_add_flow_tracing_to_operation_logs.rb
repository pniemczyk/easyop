class AddFlowTracingToOperationLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :operation_logs, :root_reference_id,     :string
    add_column :operation_logs, :reference_id,           :string
    add_column :operation_logs, :parent_operation_name,  :string
    add_column :operation_logs, :parent_reference_id,    :string

    add_index :operation_logs, :root_reference_id
    add_index :operation_logs, :reference_id, unique: true
    add_index :operation_logs, :parent_reference_id
  end
end
