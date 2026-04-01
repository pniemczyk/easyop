class CreateSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :subscriptions do |t|
      t.string :email, null: false
      t.string :name, default: ""
      t.boolean :confirmed, default: false, null: false
      t.datetime :unsubscribed_at

      t.timestamps
    end

    add_index :subscriptions, :email
  end
end
