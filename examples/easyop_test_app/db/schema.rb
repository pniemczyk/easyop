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

ActiveRecord::Schema[8.1].define(version: 2026_04_24_000000) do
  create_table "access_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "granted_at", null: false
    t.integer "payment_id", null: false
    t.datetime "revoked_at"
    t.string "tier", default: "standard", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["payment_id"], name: "index_access_grants_on_payment_id"
    t.index ["user_id", "tier"], name: "index_access_grants_on_user_id_and_tier"
    t.index ["user_id"], name: "index_access_grants_on_user_id"
  end

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

  create_table "event_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_name", null: false
    t.datetime "occurred_at", null: false
    t.text "payload_data"
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["event_name"], name: "index_event_logs_on_event_name"
    t.index ["occurred_at"], name: "index_event_logs_on_occurred_at"
  end

  create_table "operation_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.string "error_message"
    t.integer "execution_index"
    t.string "operation_name"
    t.text "params_data"
    t.string "parent_operation_name"
    t.string "parent_reference_id"
    t.datetime "performed_at"
    t.string "reference_id"
    t.text "result_data"
    t.string "root_reference_id"
    t.boolean "success"
    t.datetime "updated_at", null: false
    t.index ["parent_reference_id", "execution_index"], name: "index_operation_logs_on_parent_ref_and_exec_index"
    t.index ["parent_reference_id"], name: "index_operation_logs_on_parent_reference_id"
    t.index ["reference_id"], name: "index_operation_logs_on_reference_id", unique: true
    t.index ["root_reference_id"], name: "index_operation_logs_on_root_reference_id"
  end

  create_table "payments", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "refunded_at"
    t.string "status", default: "pending", null: false
    t.string "transaction_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["status"], name: "index_payments_on_status"
    t.index ["transaction_id"], name: "index_payments_on_transaction_id", unique: true
    t.index ["user_id"], name: "index_payments_on_user_id"
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

  add_foreign_key "access_grants", "payments"
  add_foreign_key "access_grants", "users"
  add_foreign_key "articles", "users"
  add_foreign_key "broadcasts", "articles"
  add_foreign_key "payments", "users"
end
