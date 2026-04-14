# frozen_string_literal: true

module Easyop
  module Events
    # An immutable domain event value object.
    #
    # @example
    #   event = Easyop::Events::Event.new(
    #     name:    "order.placed",
    #     payload: { order_id: 42, total: 9900 },
    #     source:  "PlaceOrder"
    #   )
    #   event.name     # => "order.placed"
    #   event.payload  # => { order_id: 42, total: 9900 }
    #   event.frozen?  # => true
    class Event
      attr_reader :name, :payload, :metadata, :timestamp, :source

      # @param name      [String]  event name, e.g. "order.placed"
      # @param payload   [Hash]    domain data extracted from ctx
      # @param metadata  [Hash]    extra envelope data (correlation_id, etc.)
      # @param timestamp [Time]    defaults to Time.now
      # @param source    [String]  class name of the emitting operation
      def initialize(name:, payload: {}, metadata: {}, timestamp: nil, source: nil)
        @name      = name.to_s.freeze
        @payload   = payload.freeze
        @metadata  = metadata.freeze
        @timestamp = (timestamp || Time.now).freeze
        @source    = source&.freeze
        freeze
      end

      # @return [Hash] serializable hash representation
      def to_h
        { name: @name, payload: @payload, metadata: @metadata,
          timestamp: @timestamp, source: @source }
      end

      def inspect
        "#<Easyop::Events::Event name=#{@name.inspect} source=#{@source.inspect}>"
      end
    end
  end
end
