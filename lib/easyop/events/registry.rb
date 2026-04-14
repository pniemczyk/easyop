# frozen_string_literal: true

module Easyop
  module Events
    # Thread-safe global registry for the event bus and handler subscriptions.
    #
    # The Registry is the coordination point between the Events plugin (producer)
    # and the EventHandlers plugin (subscriber). Neither plugin references the other
    # directly — they communicate only through the bus managed here.
    #
    # Configure the bus once at boot (e.g. in a Rails initializer):
    #
    #   Easyop::Events::Registry.bus = :memory           # default, in-process
    #   Easyop::Events::Registry.bus = :active_support   # ActiveSupport::Notifications
    #   Easyop::Events::Registry.bus = MyRabbitBus.new   # custom adapter
    #
    # Or via the global config:
    #
    #   Easyop.configure { |c| c.event_bus = :active_support }
    #
    # IMPORTANT: Configure the bus BEFORE handler classes are loaded (before
    # autoloading runs in Rails). Subscriptions are registered at class load time
    # and are bound to whatever bus is active at that moment.
    class Registry
      @mutex = Mutex.new

      class << self
        # Set the global bus adapter.
        #
        # @param bus_or_symbol [:memory, :active_support, Bus::Base, Object]
        def bus=(bus_or_symbol)
          @mutex.synchronize { @bus = _resolve_bus(bus_or_symbol) }
        end

        # Returns the active bus adapter. Defaults to a Memory bus.
        #
        # Falls back to Easyop.config.event_bus if set, then :memory.
        #
        # @return [Bus::Base]
        def bus
          @mutex.synchronize do
            @bus ||= _resolve_bus(
              defined?(Easyop.config) && Easyop.config.respond_to?(:event_bus) && Easyop.config.event_bus ||
              :memory
            )
          end
        end

        # Register a handler operation as a subscriber for +pattern+.
        #
        # Called automatically by the EventHandlers plugin when `on` is declared.
        #
        # @param pattern       [String, Regexp]  event name or glob
        # @param handler_class [Class]           operation class to invoke
        # @param async         [Boolean]         use call_async (requires Async plugin)
        # @param options       [Hash]            e.g. queue: "low"
        def register_handler(pattern:, handler_class:, async: false, **options)
          entry = { pattern: pattern, handler_class: handler_class,
                    async: async, options: options }

          @mutex.synchronize { _subscriptions << entry }

          bus.subscribe(pattern) { |event| _dispatch(event, entry) }
        end

        # Returns a copy of all registered handler entries (for introspection).
        #
        # @return [Array<Hash>]
        def subscriptions
          @mutex.synchronize { _subscriptions.dup }
        end

        # Reset the registry: drop all subscriptions and replace the bus with a
        # fresh Memory instance. Intended for use in tests (called in before/after hooks).
        def reset!
          @mutex.synchronize do
            @bus           = nil
            @subscriptions = nil
          end
        end

        private

        def _subscriptions
          @subscriptions ||= []
        end

        # @api private — exposed for specs
        def _dispatch(event, entry)
          handler_class = entry[:handler_class]

          if entry[:async] && handler_class.respond_to?(:call_async)
            # Serialize Event to a plain hash for ActiveJob compatibility.
            attrs = event.payload.merge(event_data: event.to_h)
            queue = entry[:options][:queue]
            handler_class.call_async(attrs, **(queue ? { queue: queue } : {}))
          else
            # Sync: pass Event object directly — ctx.event is the live Event instance.
            handler_class.call(event: event, **event.payload)
          end
        rescue StandardError
          # Handler failures must not propagate back to the publisher.
        end

        def _resolve_bus(bus_or_symbol)
          case bus_or_symbol
          when :memory
            Bus::Memory.new
          when :active_support
            Bus::ActiveSupportNotifications.new
          when Bus::Base
            bus_or_symbol
          when nil
            Bus::Memory.new
          else
            if bus_or_symbol.respond_to?(:publish) && bus_or_symbol.respond_to?(:subscribe)
              Bus::Custom.new(bus_or_symbol)
            else
              raise ArgumentError,
                "Unknown bus: #{bus_or_symbol.inspect}. " \
                "Use :memory, :active_support, or a bus adapter instance."
            end
          end
        end
      end
    end
  end
end
