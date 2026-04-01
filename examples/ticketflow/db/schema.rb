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

ActiveRecord::Schema[8.1].define(version: 2026_04_01_091859) do
  create_table "discount_codes", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "amount", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "discount_type", default: "percentage", null: false
    t.datetime "expires_at"
    t.integer "max_uses"
    t.datetime "updated_at", null: false
    t.integer "use_count", default: 0, null: false
    t.index ["code"], name: "index_discount_codes_on_code", unique: true
  end

  create_table "events", force: :cascade do |t|
    t.string "cover_color", default: "#6366f1"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "ends_at"
    t.string "location"
    t.boolean "published", default: false, null: false
    t.string "slug"
    t.datetime "starts_at", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "venue"
    t.index ["published"], name: "index_events_on_published"
    t.index ["slug"], name: "index_events_on_slug", unique: true
  end

  create_table "operation_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.text "error_message"
    t.string "operation_name", null: false
    t.text "params_data"
    t.datetime "performed_at", null: false
    t.boolean "success", null: false
    t.datetime "updated_at", null: false
    t.index ["operation_name"], name: "index_operation_logs_on_operation_name"
    t.index ["performed_at"], name: "index_operation_logs_on_performed_at"
    t.index ["success"], name: "index_operation_logs_on_success"
  end

  create_table "order_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "order_id", null: false
    t.integer "quantity", default: 1, null: false
    t.integer "ticket_type_id", null: false
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["ticket_type_id"], name: "index_order_items_on_ticket_type_id"
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "discount_cents", default: 0, null: false
    t.integer "discount_code_id"
    t.string "email", null: false
    t.integer "event_id", null: false
    t.string "name", null: false
    t.datetime "paid_at"
    t.text "payment_gateway_response"
    t.string "payment_reference"
    t.string "status", default: "pending", null: false
    t.integer "subtotal_cents", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["discount_code_id"], name: "index_orders_on_discount_code_id"
    t.index ["event_id"], name: "index_orders_on_event_id"
    t.index ["status"], name: "index_orders_on_status"
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "ticket_types", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "event_id", null: false
    t.string "name", null: false
    t.integer "price_cents", default: 0, null: false
    t.integer "quantity", default: 100, null: false
    t.integer "sold_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_ticket_types_on_event_id"
  end

  create_table "tickets", force: :cascade do |t|
    t.string "attendee_email"
    t.string "attendee_name"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.integer "order_id", null: false
    t.string "status", default: "active"
    t.integer "ticket_type_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_tickets_on_order_id"
    t.index ["status"], name: "index_tickets_on_status"
    t.index ["ticket_type_id"], name: "index_tickets_on_ticket_type_id"
    t.index ["token"], name: "index_tickets_on_token", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "ticket_types"
  add_foreign_key "orders", "discount_codes"
  add_foreign_key "orders", "events"
  add_foreign_key "orders", "users"
  add_foreign_key "ticket_types", "events"
  add_foreign_key "tickets", "orders"
  add_foreign_key "tickets", "ticket_types"
end
