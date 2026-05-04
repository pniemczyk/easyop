require "easyop/plugins/async"
require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/transactional"

# ── Mode 3 (Durable flows) opt-in ────────────────────────────────────────────
# Enables durable flow support: flows with `subject :order` suspend and resume
# across async steps, persisting ctx in the easy_flow_runs table.
# Run `bin/rails db:migrate` after adding the migrations to create the tables.
require "easyop/persistent_flow"
require "easyop/scheduler"

Easyop.configure do |config|
  config.strict_types = false
end

Easyop::Plugins::Instrumentation.attach_log_subscriber
