class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.string :title, null: false
      t.text :description
      t.string :venue
      t.string :location
      t.datetime :starts_at, null: false
      t.datetime :ends_at
      t.boolean :published, default: false, null: false
      t.string :cover_color, default: "#6366f1"
      t.string :slug
      t.timestamps
    end
    add_index :events, :slug, unique: true
    add_index :events, :published
  end
end
