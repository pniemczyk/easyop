class CreateOperationLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :operation_logs do |t|
      t.string :operation_name, null: false
      t.boolean :success, null: false
      t.text :error_message
      t.text :params_data
      t.float :duration_ms
      t.datetime :performed_at, null: false
      t.timestamps
    end
    add_index :operation_logs, :operation_name
    add_index :operation_logs, :success
    add_index :operation_logs, :performed_at
  end
end
