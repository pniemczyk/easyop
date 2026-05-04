require "easyop/plugins/async"
require "easyop/plugins/instrumentation"
require "easyop/simple_crypt"
require "easyop/testing" if Rails.env.test?

# ── Mode 3 (Durable flows) opt-in ────────────────────────────────────────────
# Enables durable flow support: flows with `subject :model` suspend and resume
# across async steps, persisting ctx in the easy_flow_runs table.
# Run `bin/rails db:migrate` after adding the migrations to create the tables.
require "easyop/persistent_flow"
require "easyop/scheduler"

Easyop.configure do |c|
  c.strict_types = false

  # Secret for encrypt_params in the Recording plugin.
  # Resolution order: ENV var → Rails credentials → secret_key_base (app fallback)
  # The secret must be ≥ 32 bytes. secret_key_base is used here as the development default.
  c.recording_secret = ENV.fetch("EASYOP_RECORDING_SECRET") {
    Rails.application.credentials.secret_key_base || Rails.application.secret_key_base
  }
end

# Attach the built-in log subscriber — logs every operation to Rails.logger
Easyop::Plugins::Instrumentation.attach_log_subscriber
