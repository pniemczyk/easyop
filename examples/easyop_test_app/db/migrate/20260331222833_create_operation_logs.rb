class CreateOperationLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :operation_logs do |t|
      t.string :operation_name
      t.boolean :success
      t.string :error_message
      t.text :params_data
      t.float :duration_ms
      t.datetime :performed_at

      t.timestamps
    end
  end
end
