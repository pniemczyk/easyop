class CreateAccessGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :access_grants do |t|
      t.references :user, null: false, foreign_key: true
      t.references :payment, null: false, foreign_key: true
      t.string :tier, null: false, default: "standard"
      t.datetime :granted_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :access_grants, [:user_id, :tier]
  end
end
