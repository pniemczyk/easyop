require_relative "easyop/version"
require_relative "easyop/configuration"
require_relative "easyop/ctx"
require_relative "easyop/hooks"
require_relative "easyop/rescuable"
require_relative "easyop/skip"
require_relative "easyop/schema"
require_relative "easyop/operation"
require_relative "easyop/flow_builder"
require_relative "easyop/flow"

# Optional plugins — not auto-required
# require_relative "easyop/plugins/transactional"

# Optional plugins — require explicitly or via Bundler:
# require "easyop/plugins/base"
# require "easyop/plugins/instrumentation"
# require "easyop/plugins/recording"
# require "easyop/plugins/async"

# Domain event plugins — require together or individually:
# require "easyop/events/event"
# require "easyop/events/bus"
# require "easyop/events/bus/memory"
# require "easyop/events/bus/active_support_notifications"
# require "easyop/events/bus/custom"
# require "easyop/events/bus/adapter"   # inherit this to build a custom bus
# require "easyop/events/registry"
# require "easyop/plugins/events"
# require "easyop/plugins/event_handlers"

module Easyop
  # Convenience: inherit from this instead of including Easyop::Operation
  # when you want a common base class for all your operations.
  #
  #   class ApplicationOperation
  #     include Easyop::Operation
  #
  #     rescue_from StandardError, with: :handle_unexpected
  #
  #     private
  #
  #     def handle_unexpected(e)
  #       Sentry.capture_exception(e)
  #       ctx.fail!(error: "An unexpected error occurred")
  #     end
  #   end
  #
  #   class MyOp < ApplicationOperation
  #     ...
  #   end
end
