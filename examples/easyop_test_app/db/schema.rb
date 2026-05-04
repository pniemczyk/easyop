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

ActiveRecord::Schema[8.1].define(version: 2026_05_04_100002) do
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

  create_table "easy_flow_run_steps", force: :cascade do |t|
    t.integer "attempt", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "error_class"
    t.string "error_message", limit: 500
    t.datetime "finished_at"
    t.integer "flow_run_id", null: false
    t.string "operation_class", null: false
    t.datetime "started_at", null: false
    t.string "status", default: "running", null: false
    t.integer "step_index", null: false
    t.datetime "updated_at", null: false
    t.index ["flow_run_id", "step_index"], name: "idx_efrs_run_step"
    t.index ["flow_run_id"], name: "index_easy_flow_run_steps_on_flow_run_id"
  end

  create_table "easy_flow_runs", force: :cascade do |t|
    t.text "context_data", default: "{}", null: false
    t.datetime "created_at", null: false
    t.integer "current_step_index", default: 0, null: false
    t.datetime "finished_at"
    t.string "flow_class", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "subject_id"
    t.string "subject_type"
    t.string "tags"
    t.datetime "updated_at", null: false
    t.index ["flow_class"], name: "index_easy_flow_runs_on_flow_class"
    t.index ["status"], name: "index_easy_flow_runs_on_status"
    t.index ["subject_type", "subject_id"], name: "idx_efr_subject"
  end

  create_table "easy_scheduled_tasks", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "claimed_at"
    t.string "claimed_by"
    t.datetime "created_at", null: false
    t.string "cron"
    t.text "ctx_data", null: false
    t.string "dedup_key"
    t.string "last_error_class"
    t.text "last_error_message"
    t.integer "lock_version", default: 0, null: false
    t.datetime "locked_until"
    t.integer "max_attempts", default: 3, null: false
    t.string "operation_class", null: false
    t.integer "parent_id"
    t.string "recording_root_reference_id"
    t.datetime "run_at", null: false
    t.string "state", default: "scheduled", null: false
    t.text "tags"
    t.datetime "updated_at", null: false
    t.index ["dedup_key"], name: "idx_est_dedup_key", unique: true, where: "dedup_key IS NOT NULL"
    t.index ["state", "run_at"], name: "idx_est_due"
  end

  create_table "easy_workflow_steps", force: :cascade do |t|
    t.datetime "canceled_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "easy_workflow_id", null: false
    t.text "error_backtrace"
    t.string "error_class_name"
    t.string "error_message"
    t.datetime "failed_at"
    t.string "job_id"
    t.string "outcome"
    t.string "recording_root_reference_id"
    t.datetime "scheduled_for", null: false
    t.datetime "skipped_at"
    t.datetime "started_at"
    t.string "state", default: "scheduled", null: false
    t.string "step_name", null: false
    t.datetime "updated_at", null: false
    t.index ["easy_workflow_id", "created_at"], name: "index_easy_workflow_steps_on_easy_workflow_id_and_created_at"
    t.index ["easy_workflow_id"], name: "index_easy_workflow_steps_on_easy_workflow_id"
    t.index ["scheduled_for"], name: "index_easy_workflow_steps_on_scheduled_for"
    t.index ["state"], name: "index_easy_workflow_steps_on_state"
    t.index ["step_name"], name: "index_easy_workflow_steps_on_step_name"
  end

  create_table "easy_workflows", force: :cascade do |t|
    t.boolean "allow_multiple", default: false, null: false
    t.text "context_data"
    t.datetime "created_at", null: false
    t.string "current_step_name"
    t.bigint "hero_id"
    t.string "hero_type"
    t.string "next_step_name"
    t.string "recording_root_reference_id"
    t.string "state", default: "ready", null: false
    t.datetime "transitioned_at"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["hero_type", "hero_id"], name: "index_easy_workflows_on_hero_type_and_hero_id"
    t.index ["state"], name: "index_easy_workflows_on_state"
    t.index ["transitioned_at"], name: "index_easy_workflows_on_transitioned_at"
    t.index ["type", "hero_type", "hero_id"], name: "idx_easy_workflows_one_ongoing", unique: true, where: "state NOT IN ('finished', 'canceled') AND allow_multiple = FALSE"
    t.index ["type"], name: "index_easy_workflows_on_type"
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
  add_foreign_key "easy_flow_run_steps", "easy_flow_runs", column: "flow_run_id"
  add_foreign_key "easy_workflow_steps", "easy_workflows"
  add_foreign_key "payments", "users"
end
