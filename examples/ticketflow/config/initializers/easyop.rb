require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/transactional"

# ── Mode 3 (Durable flows) opt-in ────────────────────────────────────────────
# Uncomment to enable durable flow support (suspend/resume via DB scheduler).
# Run `rails g easyop:install` to generate the required migrations.
#
# require "easyop/persistent_flow"
# require "easyop/scheduler"

Easyop.configure do |config|
  config.strict_types = false
end

Easyop::Plugins::Instrumentation.attach_log_subscriber
