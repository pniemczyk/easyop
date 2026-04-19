class CreatePayments < ActiveRecord::Migration[8.1]
  def change
    create_table :payments do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.string :transaction_id, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :refunded_at
      t.timestamps
    end
    add_index :payments, :transaction_id, unique: true
    add_index :payments, :status
  end
end
