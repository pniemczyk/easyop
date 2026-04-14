# frozen_string_literal: true

class AddResultDataToOperationLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :operation_logs, :result_data, :text  # JSON — selected ctx output via record_result DSL
  end
end
