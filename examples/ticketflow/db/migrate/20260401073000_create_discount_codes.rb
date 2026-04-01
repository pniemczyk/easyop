class CreateDiscountCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :discount_codes do |t|
      t.string :code, null: false
      t.string :discount_type, null: false, default: "percentage"
      t.integer :amount, null: false
      t.integer :max_uses
      t.integer :use_count, null: false, default: 0
      t.datetime :expires_at
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :discount_codes, :code, unique: true
  end
end
