# frozen_string_literal: true

module Easyop
  module Events
    module Bus
      # In-process, synchronous bus. Default adapter — requires no external gems.
      #
      # Thread-safe: subscriptions are protected by a Mutex, and publish snapshots
      # the subscriber list before calling handlers so the lock is not held
      # during handler execution (prevents deadlocks).
      #
      # @example
      #   bus = Easyop::Events::Bus::Memory.new
      #   bus.subscribe("order.placed") { |e| puts e.name }
      #   bus.publish(Easyop::Events::Event.new(name: "order.placed"))
      class Memory < Base
        def initialize
          @subscribers = []
          @mutex       = Mutex.new
        end

        # Deliver +event+ to all matching subscribers.
        # Handlers are called outside the lock; failures in individual handlers
        # are swallowed so other handlers still run.
        #
        # @param event [Easyop::Events::Event]
        def publish(event)
          subs = @mutex.synchronize { @subscribers.dup }
          subs.each do |sub|
            sub[:handler].call(event) if _pattern_matches?(sub[:pattern], event.name)
          rescue StandardError
            # Individual handler failures must not prevent other handlers from running.
          end
        end

        # Register a handler block for events matching +pattern+.
        #
        # @param pattern [String, Regexp]  exact name, glob, or Regexp
        # @return [Hash] subscription handle (pass to #unsubscribe to remove)
        def subscribe(pattern, &block)
          entry = { pattern: pattern, handler: block }
          @mutex.synchronize { @subscribers << entry }
          entry
        end

        # Remove a previously registered subscription.
        # @param handle [Hash] the value returned by #subscribe
        def unsubscribe(handle)
          @mutex.synchronize { @subscribers.delete(handle) }
        end

        # Remove all subscriptions. Useful in tests.
        def clear!
          @mutex.synchronize { @subscribers.clear }
        end

        # @return [Integer] number of active subscriptions
        def subscriber_count
          @mutex.synchronize { @subscribers.size }
        end
      end
    end
  end
end
