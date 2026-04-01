class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :user, foreign_key: true
      t.references :event, null: false, foreign_key: true
      t.string :email, null: false
      t.string :name, null: false
      t.string :status, null: false, default: "pending"
      t.integer :subtotal_cents, null: false, default: 0
      t.integer :discount_cents, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.references :discount_code, foreign_key: true
      t.string :payment_reference
      t.datetime :paid_at
      t.timestamps
    end
    add_index :orders, :status
  end
end
