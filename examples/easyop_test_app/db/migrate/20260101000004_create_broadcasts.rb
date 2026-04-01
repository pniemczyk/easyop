class CreateBroadcasts < ActiveRecord::Migration[8.0]
  def change
    create_table :broadcasts do |t|
      t.string :subject, null: false
      t.text :body, null: false
      t.datetime :sent_at
      t.references :article, null: true, foreign_key: true

      t.timestamps
    end
  end
end
