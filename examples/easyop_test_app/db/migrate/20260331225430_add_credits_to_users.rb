class AddCreditsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :credits, :integer, default: 0, null: false
  end
end
