# frozen_string_literal: true

module Easyop
  module Plugins
    # Instruments every operation call via ActiveSupport::Notifications.
    #
    # Install on ApplicationOperation (propagates to all subclasses):
    #
    #   class ApplicationOperation
    #     include Easyop::Operation
    #     plugin Easyop::Plugins::Instrumentation
    #   end
    #
    # Event: "easyop.operation.call"
    # Payload keys:
    #   :operation  — String class name, e.g. "Users::Register"
    #   :success    — Boolean
    #   :error      — String | nil  (ctx.error on failure)
    #   :duration   — Float ms
    #   :ctx        — The Easyop::Ctx object (read-only reference)
    #
    # Subscribe manually:
    #   ActiveSupport::Notifications.subscribe("easyop.operation.call") do |event|
    #     Rails.logger.info "[EasyOp] #{event.payload[:operation]} — #{event.payload[:success] ? 'ok' : 'FAILED'}"
    #   end
    #
    # Or use the built-in log subscriber:
    #   Easyop::Plugins::Instrumentation.attach_log_subscriber
    module Instrumentation
      EVENT = "easyop.operation.call"

      def self.install(base, **_options)
        base.prepend(RunWrapper)
      end

      # Attach a default subscriber that logs to Rails.logger (or stdout).
      # Call once in an initializer: Easyop::Plugins::Instrumentation.attach_log_subscriber
      def self.attach_log_subscriber
        ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          p     = event.payload
          next if p[:operation].nil?

          status = p[:success] ? "ok" : "FAILED"
          ms     = event.duration.round(1)
          line   = "[EasyOp] #{p[:operation]} #{status} (#{ms}ms)"
          line  += " — #{p[:error]}" if p[:error]

          logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : Logger.new($stdout)
          if p[:success]
            logger.info line
          else
            logger.warn line
          end
        end
      end

      module RunWrapper
        def _easyop_run(ctx, raise_on_failure:)
          start   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          payload = { operation: self.class.name, success: nil, error: nil, duration: nil, ctx: ctx }

          ActiveSupport::Notifications.instrument(EVENT, payload) do
            super.tap do
              payload[:success]  = ctx.success?
              payload[:error]    = ctx.error if ctx.failure?
              payload[:duration] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
            end
          end
        end
      end
    end
  end
end
