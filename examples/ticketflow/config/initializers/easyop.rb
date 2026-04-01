require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/transactional"

Easyop.configure do |config|
  config.strict_types = false
end

Easyop::Plugins::Instrumentation.attach_log_subscriber
