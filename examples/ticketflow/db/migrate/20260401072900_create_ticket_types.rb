class CreateTicketTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_types do |t|
      t.references :event, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :price_cents, null: false, default: 0
      t.integer :quantity, null: false, default: 100
      t.integer :sold_count, null: false, default: 0
      t.timestamps
    end
  end
end
