# frozen_string_literal: true

module Easyop
  module Events
    module Bus
      # Bus adapter backed by ActiveSupport::Notifications.
      #
      # Requires activesupport (not auto-required). Raises LoadError if unavailable.
      #
      # @example
      #   Easyop::Events::Registry.bus = :active_support
      #
      #   # or manually:
      #   bus = Easyop::Events::Bus::ActiveSupportNotifications.new
      #   Easyop::Events::Registry.bus = bus
      class ActiveSupportNotifications < Base
        # Publish +event+ via ActiveSupport::Notifications.instrument.
        # The full event hash (name, payload, metadata, timestamp, source) is passed
        # as the AS notification payload.
        #
        # @param event [Easyop::Events::Event]
        def publish(event)
          _ensure_as!
          ::ActiveSupport::Notifications.instrument(event.name, event.to_h)
        end

        # Subscribe to events matching +pattern+ via ActiveSupport::Notifications.subscribe.
        # Glob patterns are converted to Regexp before passing to AS.
        #
        # @param pattern [String, Regexp]
        # @return [Object] AS subscription handle
        def subscribe(pattern, &block)
          _ensure_as!

          as_pattern = _as_pattern(pattern)

          ::ActiveSupport::Notifications.subscribe(as_pattern) do |*args|
            as_event     = ::ActiveSupport::Notifications::Event.new(*args)
            p            = as_event.payload

            # Reconstruct an Easyop::Events::Event from the AS notification payload.
            easyop_event = Event.new(
              name:      (p[:name] || as_event.name).to_s,
              payload:   p[:payload]  || {},
              metadata:  p[:metadata] || {},
              timestamp: p[:timestamp],
              source:    p[:source]
            )
            block.call(easyop_event)
          end
        end

        # Unsubscribe using the handle returned by #subscribe.
        # @param handle [Object] AS subscription object
        def unsubscribe(handle)
          _ensure_as!
          ::ActiveSupport::Notifications.unsubscribe(handle)
        end

        private

        # Convert a pattern for use with AS::Notifications.subscribe.
        # AS accepts exact strings or Regexp (not globs), so convert globs first.
        def _as_pattern(pattern)
          case pattern
          when Regexp then pattern
          when String
            pattern.include?("*") ? _glob_to_regex(pattern) : pattern
          end
        end

        def _ensure_as!
          return if defined?(::ActiveSupport::Notifications)

          raise LoadError,
            "ActiveSupport::Notifications is required for this bus adapter. " \
            "Add 'activesupport' to your Gemfile."
        end
      end
    end
  end
end
