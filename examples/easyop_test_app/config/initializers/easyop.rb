require "easyop/plugins/instrumentation"

Easyop.configure do |c|
  c.strict_types = false
end

# Attach the built-in log subscriber — logs every operation to Rails.logger
Easyop::Plugins::Instrumentation.attach_log_subscriber
