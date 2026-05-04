# frozen_string_literal: true

module Easyop
  module PersistentFlow
    module Backoff
      module_function

      # Compute retry delay in seconds.
      # attempt is 1-indexed (1 = first retry after the initial failure).
      #
      # @param strategy [:constant, :linear, :exponential, #call]
      # @param base     [Numeric, #to_i, #call] base delay (seconds) or callable(attempt)
      # @param attempt  [Integer] retry attempt number (1-indexed)
      # @return [Numeric] delay in seconds
      def compute(strategy, base, attempt)
        return base.call(attempt).to_f if base.respond_to?(:call)
        seconds = base.respond_to?(:to_i) ? base.to_i : Integer(base)
        case strategy
        when :constant    then seconds
        when :linear      then seconds * attempt
        when :exponential then (attempt**4) + seconds + rand(30)
        else                   seconds
        end
      end
    end
  end
end
