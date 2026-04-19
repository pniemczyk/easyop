# frozen_string_literal: true

module Easyop
  module Testing
    # Assertion helpers for Easyop::Plugins::Events.
    #
    # Capture events emitted during a block, then assert on them:
    #
    #   events = capture_events(bus) do
    #     MyOp.call(order_id: 1)
    #   end
    #   assert_event_emitted events, "order.placed"
    #   assert_event_payload events, "order.placed", order_id: 1
    #   assert_event_source  events, "order.placed", "MyOp"
    #   assert_event_on      events, "order.placed", :success
    #   assert_no_events     events
    #
    module EventAssertions
      # Subscribe to all events on +bus+ for the duration of the block.
      # Returns an array of Easyop::Events::Event objects emitted during the block.
      #
      # @param bus [Easyop::Events::Bus::Base, nil]  defaults to global registry bus
      # @yieldreturn [void]
      # @return [Array<Easyop::Events::Event>]
      def capture_events(bus = nil, &block)
        resolved_bus = bus || Easyop::Events::Registry.bus
        captured     = []
        handle       = resolved_bus.subscribe("**") { |e| captured << e }
        block.call
        captured
      ensure
        resolved_bus.unsubscribe(handle) if handle
      end

      # ── Presence assertions ──────────────────────────────────────────────

      # Assert that an event with +name+ was emitted.
      def assert_event_emitted(events, name, msg: nil)
        matched = events.select { |e| e.name == name.to_s }
        _easyop_assert matched.any?,
          msg || "Expected event #{name.inspect} to be emitted. " \
                 "Events emitted: #{events.map(&:name).inspect}"
      end

      # Assert no events were emitted, or that a named event was NOT emitted.
      #
      #   assert_no_events events
      #   assert_no_events events, "order.placed"
      def assert_no_events(events, name = nil, msg: nil)
        if name
          matched = events.select { |e| e.name == name.to_s }
          _easyop_assert matched.empty?,
            msg || "Expected event #{name.inspect} NOT to be emitted, but it was."
        else
          _easyop_assert events.empty?,
            msg || "Expected no events to be emitted but got: #{events.map(&:name).inspect}"
        end
      end

      # ── Payload assertions ───────────────────────────────────────────────

      # Assert the payload of an emitted event.
      # Values may be exact matches or Class objects (type check).
      #
      #   assert_event_payload events, "order.placed", order_id: 1, total: 99
      #   assert_event_payload events, "order.placed", order_id: Integer   # type check
      def assert_event_payload(events, name, msg: nil, **expected_payload)
        matched = events.select { |e| e.name == name.to_s }
        _easyop_assert matched.any?,
          "Expected event #{name.inspect} to be emitted but it wasn't"

        payload_ok = matched.any? do |e|
          expected_payload.all? do |key, expected_val|
            actual_val = e.payload[key] || e.payload[key.to_s]
            if expected_val.is_a?(Class)
              actual_val.is_a?(expected_val)
            else
              actual_val == expected_val
            end
          end
        end

        _easyop_assert payload_ok,
          msg || "Event #{name.inspect} was emitted but not with payload #{expected_payload.inspect}. " \
                 "Actual payloads: #{matched.map(&:payload).inspect}"
      end

      # ── Source assertion ─────────────────────────────────────────────────

      # Assert the source (emitting operation class name) of a named event.
      #
      #   assert_event_source events, "order.placed", "PlaceOrder"
      def assert_event_source(events, name, source, msg: nil)
        matched = events.select { |e| e.name == name.to_s }
        _easyop_assert matched.any?,
          "Expected event #{name.inspect} to be emitted but it wasn't"

        _easyop_assert matched.any? { |e| e.source.to_s == source.to_s },
          msg || "Event #{name.inspect} was emitted but not from source #{source.inspect}. " \
                 "Actual sources: #{matched.map(&:source).inspect}"
      end

      # ── On-trigger assertion ─────────────────────────────────────────────

      # Assert that a named event was declared with a given :on trigger on the op class.
      # Inspects _emitted_events metadata on the operation class (not from captured events).
      #
      #   assert_event_on MyOp, "order.placed", :success
      def assert_event_on(op_class, name, on_trigger, msg: nil)
        _easyop_assert op_class.respond_to?(:_emitted_events),
          "#{op_class.inspect} does not have Events plugin installed"

        decl = op_class._emitted_events.find { |e| e[:name] == name.to_s }
        _easyop_assert decl,
          "No emits declaration for #{name.inspect} on #{op_class.inspect}"

        _easyop_assert_equal on_trigger.to_sym, decl[:on],
          msg || "Expected event #{name.inspect} to be declared on: #{on_trigger.inspect}, " \
                 "got on: #{decl[:on].inspect}"
      end
    end
  end
end
