require "easyop/plugins/async"
require "easyop/plugins/base"
require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/transactional"

class ApplicationOperation
  include Easyop::Operation

  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording, model: OperationLog
  plugin Easyop::Plugins::Transactional

  rescue_from StandardError do |e|
    Rails.logger.error "[#{self.class.name}] Error: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    ctx.fail!(error: e.message)
  end
end
