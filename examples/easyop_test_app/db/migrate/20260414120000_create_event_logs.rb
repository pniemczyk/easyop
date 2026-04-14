class CreateEventLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :event_logs do |t|
      t.string   :event_name, null: false
      t.string   :source
      t.text     :payload_data
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :event_logs, :event_name
    add_index :event_logs, :occurred_at
  end
end
