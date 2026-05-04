class CreateEasyFlowRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :easy_flow_runs do |t|
      t.string  :flow_class,         null: false
      t.text    :context_data,       null: false, default: '{}'
      t.string  :status,             null: false, default: 'pending'
      t.integer :current_step_index, null: false, default: 0

      # Polymorphic subject (set via `subject :order` DSL)
      t.string  :subject_type, null: true
      t.bigint  :subject_id,   null: true

      t.string  :tags, null: true

      t.datetime :started_at,  null: true
      t.datetime :finished_at, null: true

      t.timestamps
    end

    add_index :easy_flow_runs, :status
    add_index :easy_flow_runs, :flow_class
    add_index :easy_flow_runs, [:subject_type, :subject_id],
              name: 'idx_efr_subject'
  end
end
