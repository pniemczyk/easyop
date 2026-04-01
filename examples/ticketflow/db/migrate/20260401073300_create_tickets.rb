class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets do |t|
      t.references :order, null: false, foreign_key: true
      t.references :ticket_type, null: false, foreign_key: true
      t.string :token, null: false
      t.string :attendee_name
      t.string :attendee_email
      t.string :status, default: "active"
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :tickets, :token, unique: true
    add_index :tickets, :status
  end
end
