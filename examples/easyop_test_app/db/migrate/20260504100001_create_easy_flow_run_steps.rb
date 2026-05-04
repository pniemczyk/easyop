class CreateEasyFlowRunSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :easy_flow_run_steps do |t|
      t.references :flow_run, null: false, foreign_key: { to_table: :easy_flow_runs }

      t.integer :step_index,      null: false
      t.string  :operation_class, null: false
      t.string  :status,          null: false, default: 'running'
      t.integer :attempt,         null: false, default: 0

      t.string :error_class,   null: true
      t.string :error_message, null: true, limit: 500

      t.datetime :started_at,  null: false
      t.datetime :finished_at, null: true

      t.timestamps
    end

    add_index :easy_flow_run_steps, [:flow_run_id, :step_index],
              name: 'idx_efrs_run_step'
  end
end
