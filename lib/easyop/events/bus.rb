# frozen_string_literal: true

module Easyop
  module Events
    # Namespace for bus adapters.
    # All adapters inherit from Easyop::Events::Bus::Base.
    module Bus
      # Abstract base for bus adapters.
      #
      # Subclasses must implement:
      #   #publish(event)          — deliver event to matching subscribers
      #   #subscribe(pattern, &block) — register a handler block
      #
      # Optionally override:
      #   #unsubscribe(handle)     — remove a subscription (handle is return value of #subscribe)
      class Base
        # @param event [Easyop::Events::Event]
        def publish(event)
          raise NotImplementedError, "#{self.class}#publish must be implemented"
        end

        # @param pattern [String, Regexp]  event name, glob ("order.*"), or Regexp
        # @yield [event] called when a matching event is published
        # @return [Object] subscription handle (adapter-specific)
        def subscribe(pattern, &block)
          raise NotImplementedError, "#{self.class}#subscribe must be implemented"
        end

        # Remove a subscription created by #subscribe.
        # @param handle [Object] the value returned by #subscribe
        def unsubscribe(handle)
          # default no-op — adapters may override
        end

        private

        # Returns true when +pattern+ matches +event_name+.
        # Supports exact strings, glob patterns ("order.*", "order.**"), and Regexp.
        #
        # Glob rules:
        #   "*"  — matches any segment that doesn't cross a dot
        #   "**" — matches any string including dots (greedy)
        #
        # @param pattern    [String, Regexp]
        # @param event_name [String]
        def _pattern_matches?(pattern, event_name)
          case pattern
          when Regexp
            pattern.match?(event_name)
          when String
            pattern.include?("*") ? _glob_to_regex(pattern).match?(event_name) : pattern == event_name
          end
        end

        # @param glob [String]  e.g. "order.*" or "warehouse.**"
        # @return [Regexp]
        def _glob_to_regex(glob)
          escaped = Regexp.escape(glob)
                          .gsub("\\*\\*", ".+")
                          .gsub("\\*",    "[^.]+")
          Regexp.new("\\A#{escaped}\\z")
        end
      end
    end
  end
end
