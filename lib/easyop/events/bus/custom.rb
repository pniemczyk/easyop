# frozen_string_literal: true

module Easyop
  module Events
    module Bus
      # Wraps any user-supplied bus adapter.
      #
      # The adapter must respond to:
      #   #publish(event)
      #   #subscribe(pattern, &block)
      #
      # Optionally:
      #   #unsubscribe(handle)
      #
      # @example Wrapping a RabbitMQ adapter
      #   class MyRabbitBus
      #     def publish(event) = rabbit.publish(event.to_h, routing_key: event.name)
      #     def subscribe(pattern, &block) = rabbit.subscribe(pattern) { |msg| block.call(reconstruct(msg)) }
      #   end
      #
      #   Easyop::Events::Registry.bus = MyRabbitBus.new
      #
      # @example Passing via Custom wrapper explicitly
      #   Easyop::Events::Registry.bus = Easyop::Events::Bus::Custom.new(MyRabbitBus.new)
      class Custom < Base
        # @param adapter [Object] must respond to #publish and #subscribe
        # @raise [ArgumentError] if adapter does not meet the interface
        def initialize(adapter)
          unless adapter.respond_to?(:publish) && adapter.respond_to?(:subscribe)
            raise ArgumentError,
              "Custom bus adapter must respond to #publish(event) and " \
              "#subscribe(pattern, &block). Got: #{adapter.inspect}"
          end
          @adapter = adapter
        end

        def publish(event)
          @adapter.publish(event)
        end

        def subscribe(pattern, &block)
          @adapter.subscribe(pattern, &block)
        end

        def unsubscribe(handle)
          @adapter.unsubscribe(handle) if @adapter.respond_to?(:unsubscribe)
        end
      end
    end
  end
end
