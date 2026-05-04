class CreateEasyScheduledTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :easy_scheduled_tasks do |t|
      t.string   :operation_class,    null: false
      t.text     :ctx_data,           null: false
      t.datetime :run_at,             null: false
      t.string   :cron,               null: true
      t.integer  :parent_id,          null: true
      t.string   :state,              null: false, default: 'scheduled'
      t.string   :claimed_by,         null: true
      t.datetime :claimed_at,         null: true
      t.datetime :locked_until,       null: true
      t.integer  :lock_version,       null: false, default: 0
      t.integer  :attempts,           null: false, default: 0
      t.integer  :max_attempts,       null: false, default: 3
      t.string   :last_error_class,   null: true
      t.text     :last_error_message, null: true
      t.text     :tags,               null: true
      t.string   :dedup_key,          null: true
      t.string   :recording_root_reference_id, null: true

      t.timestamps
    end

    add_index :easy_scheduled_tasks, [:state, :run_at], name: 'idx_est_due'
    add_index :easy_scheduled_tasks, :dedup_key,
              unique: true, where: 'dedup_key IS NOT NULL',
              name: 'idx_est_dedup_key'
  end
end
