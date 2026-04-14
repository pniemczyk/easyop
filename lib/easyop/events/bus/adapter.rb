# frozen_string_literal: true

module Easyop
  module Events
    module Bus
      # Inheritable base class for custom bus implementations.
      #
      # Subclass this (not +Bus::Base+) when building a transport adapter for
      # an external message broker, pub/sub system, or any custom delivery
      # mechanism. +Bus::Base+ defines the required interface and glob helpers.
      # +Bus::Adapter+ adds two production-grade utilities on top:
      #
      #   _safe_invoke(handler, event)   — call a handler, swallow StandardError
      #   _compile_pattern(pattern)      — glob/string → cached Regexp
      #
      # Both are protected so they are accessible in subclasses but not part
      # of the external bus interface.
      #
      # == Minimum contract
      #
      # Override +#publish+ and +#subscribe+. Override +#unsubscribe+ if your
      # transport supports subscription cancellation.
      #
      # == Example — minimal adapter
      #
      #   class PrintBus < Easyop::Events::Bus::Adapter
      #     def initialize
      #       super
      #       @subs  = []
      #       @mutex = Mutex.new
      #     end
      #
      #     def publish(event)
      #       snap = @mutex.synchronize { @subs.dup }
      #       snap.each do |sub|
      #         _safe_invoke(sub[:handler], event) if _pattern_matches?(sub[:pattern], event.name)
      #       end
      #     end
      #
      #     def subscribe(pattern, &block)
      #       handle = { pattern: _compile_pattern(pattern), handler: block }
      #       @mutex.synchronize { @subs << handle }
      #       handle
      #     end
      #
      #     def unsubscribe(handle)
      #       @mutex.synchronize { @subs.delete(handle) }
      #     end
      #   end
      #
      # == Example — decorator (wraps another bus)
      #
      #   class LoggingBus < Easyop::Events::Bus::Adapter
      #     def initialize(inner)
      #       super()
      #       @inner = inner
      #     end
      #
      #     def publish(event)
      #       Rails.logger.info "[bus:publish] #{event.name} payload=#{event.payload}"
      #       @inner.publish(event)
      #     end
      #
      #     def subscribe(pattern, &block)
      #       @inner.subscribe(pattern, &block)
      #     end
      #
      #     def unsubscribe(handle)
      #       @inner.unsubscribe(handle)
      #     end
      #   end
      #
      #   Easyop::Events::Registry.bus = LoggingBus.new(Easyop::Events::Bus::Memory.new)
      class Adapter < Base
        protected

        # Call +handler+ with +event+, rescuing any StandardError.
        #
        # Use this inside your +#publish+ implementation so one broken handler
        # never prevents other handlers from running and never surfaces an
        # exception to the event producer.
        #
        # @param handler [#call]
        # @param event   [Easyop::Events::Event]
        # @return [void]
        def _safe_invoke(handler, event)
          handler.call(event)
        rescue StandardError
          # Intentionally swallowed — individual handler failures must not
          # propagate to the caller or block remaining handlers.
        end

        # Compile +pattern+ into a +Regexp+, memoized per unique pattern value.
        #
        # Results are cached in a per-instance hash so glob→Regexp conversion
        # happens only once regardless of how many events are published.
        #
        # String patterns without wildcards are anchored literally.
        # Glob patterns follow the same rules as +Bus::Base#_glob_to_regex+:
        #   "*"  — any single dot-separated segment
        #   "**" — any sequence of characters including dots
        #
        # @param pattern [String, Regexp]
        # @return [Regexp]
        def _compile_pattern(pattern)
          return pattern if pattern.is_a?(Regexp)

          @_pattern_cache ||= {}
          @_pattern_cache[pattern] ||=
            if pattern.include?("*")
              _glob_to_regex(pattern)
            else
              Regexp.new("\\A#{Regexp.escape(pattern)}\\z")
            end
        end
      end
    end
  end
end
