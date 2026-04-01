# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_31_225430) do
  create_table "articles", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.boolean "published", default: false, null: false
    t.datetime "published_at"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_articles_on_user_id"
  end

  create_table "broadcasts", force: :cascade do |t|
    t.integer "article_id"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "sent_at"
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_broadcasts_on_article_id"
  end

  create_table "operation_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.string "error_message"
    t.string "operation_name"
    t.text "params_data"
    t.datetime "performed_at"
    t.boolean "success"
    t.datetime "updated_at", null: false
  end

  create_table "subscriptions", force: :cascade do |t|
    t.boolean "confirmed", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", default: ""
    t.datetime "unsubscribed_at"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_subscriptions_on_email"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "credits", default: 0, null: false
    t.string "email", null: false
    t.string "name", null: false
    t.boolean "newsletter_opt_in", default: false, null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "articles", "users"
  add_foreign_key "broadcasts", "articles"
end
