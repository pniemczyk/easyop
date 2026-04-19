# frozen_string_literal: true

require "test_helper"

class Easyop::Testing::EventAssertionsTest < Minitest::Test
  include EasyopTestHelper
  include Easyop::Testing::Assertions
  include Easyop::Testing::EventAssertions

  # ── helpers ───────────────────────────────────────────────────────────────────

  def setup
    super
    Easyop::Events::Registry.reset!
  end

  def teardown
    Easyop::Events::Registry.reset!
    super
  end

  # Create a dedicated in-process bus shared between the op and capture_events.
  def fresh_bus
    Easyop::Events::Bus::Memory.new
  end

  # Build an operation class that uses the Events plugin with the given bus.
  def make_op(bus:, &call_block)
    b = bus
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events, bus: b
    end
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  # ── capture_events ────────────────────────────────────────────────────────────

  def test_capture_events_returns_empty_array_when_nothing_emitted
    bus    = fresh_bus
    op     = make_op(bus: bus) { }
    events = capture_events(bus) { op.call }
    assert_empty events
  end

  def test_capture_events_captures_events_emitted_during_block
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "test.happened", on: :success

    events = capture_events(bus) { op.call }
    assert_equal 1, events.size
  end

  def test_capture_events_returns_event_objects
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "test.happened", on: :success

    events = capture_events(bus) { op.call }
    assert_instance_of Easyop::Events::Event, events.first
  end

  def test_capture_events_captures_correct_event_name
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "order.placed", on: :success

    events = capture_events(bus) { op.call }
    assert_equal "order.placed", events.first.name
  end

  def test_capture_events_unsubscribes_after_block
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "test.happened", on: :success

    capture_events(bus) { }
    events_after = []
    sub = bus.subscribe("**") { |e| events_after << e }
    op.call
    bus.unsubscribe(sub)

    # Events from after the capture block should still be received by new subscribers
    assert_equal 1, events_after.size
  end

  # ── assert_event_emitted ──────────────────────────────────────────────────────

  def test_assert_event_emitted_passes_when_event_name_is_captured
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "order.placed", on: :success

    events = capture_events(bus) { op.call }
    assert_silent { assert_event_emitted(events, "order.placed") }
  end

  def test_assert_event_emitted_fails_when_event_not_captured
    bus    = fresh_bus
    events = capture_events(bus) { }
    assert_raises(Minitest::Assertion) { assert_event_emitted(events, "missing.event") }
  end

  # ── assert_no_events ─────────────────────────────────────────────────────────

  def test_assert_no_events_passes_when_no_events_captured
    bus    = fresh_bus
    events = capture_events(bus) { }
    assert_silent { assert_no_events(events) }
  end

  def test_assert_no_events_fails_when_events_were_captured
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "something.happened", on: :always

    events = capture_events(bus) { op.call }
    assert_raises(Minitest::Assertion) { assert_no_events(events) }
  end

  def test_assert_no_events_with_name_passes_when_that_event_not_emitted
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "order.placed", on: :success

    events = capture_events(bus) { op.call }
    assert_silent { assert_no_events(events, "order.failed") }
  end

  def test_assert_no_events_with_name_fails_when_that_event_was_emitted
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "order.placed", on: :success

    events = capture_events(bus) { op.call }
    assert_raises(Minitest::Assertion) { assert_no_events(events, "order.placed") }
  end

  # ── assert_event_payload ──────────────────────────────────────────────────────

  def test_assert_event_payload_passes_when_payload_matches
    bus = fresh_bus
    op  = make_op(bus: bus) { ctx[:value] = 42 }
    op.emits "test.happened", on: :success, payload: ->(ctx) { { value: ctx[:value] } }

    events = capture_events(bus) { op.call }
    assert_silent { assert_event_payload(events, "test.happened", value: 42) }
  end

  def test_assert_event_payload_fails_when_payload_does_not_match
    bus = fresh_bus
    op  = make_op(bus: bus) { ctx[:value] = 42 }
    op.emits "test.happened", on: :success, payload: ->(ctx) { { value: ctx[:value] } }

    events = capture_events(bus) { op.call }
    assert_raises(Minitest::Assertion) do
      assert_event_payload(events, "test.happened", value: 999)
    end
  end

  def test_assert_event_payload_with_class_type_check_passes
    bus = fresh_bus
    op  = make_op(bus: bus) { ctx[:count] = 5 }
    op.emits "test.counted", on: :success, payload: ->(ctx) { { count: ctx[:count] } }

    events = capture_events(bus) { op.call }
    assert_silent { assert_event_payload(events, "test.counted", count: Integer) }
  end

  def test_assert_event_payload_with_class_type_check_fails_when_wrong_type
    bus = fresh_bus
    op  = make_op(bus: bus) { ctx[:count] = 5 }
    op.emits "test.counted", on: :success, payload: ->(ctx) { { count: ctx[:count] } }

    events = capture_events(bus) { op.call }
    assert_raises(Minitest::Assertion) do
      assert_event_payload(events, "test.counted", count: String)
    end
  end

  # ── assert_event_on ───────────────────────────────────────────────────────────

  def test_assert_event_on_passes_when_correct_trigger
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "order.placed", on: :success

    assert_silent { assert_event_on(op, "order.placed", :success) }
  end

  def test_assert_event_on_fails_when_wrong_trigger
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "order.placed", on: :success

    assert_raises(Minitest::Assertion) { assert_event_on(op, "order.placed", :failure) }
  end

  def test_assert_event_on_fails_when_event_not_declared
    bus = fresh_bus
    op  = make_op(bus: bus) { }

    assert_raises(Minitest::Assertion) { assert_event_on(op, "undeclared.event", :success) }
  end

  # ── assert_event_source ───────────────────────────────────────────────────────

  def test_assert_event_source_passes_when_source_matches
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "test.happened", on: :success
    set_const("TestSourceOp", op)

    events = capture_events(bus) { op.call }
    assert_silent { assert_event_source(events, "test.happened", "TestSourceOp") }
  end

  def test_assert_event_source_fails_when_source_does_not_match
    bus = fresh_bus
    op  = make_op(bus: bus) { }
    op.emits "test.happened", on: :success
    set_const("TestSourceOp2", op)

    events = capture_events(bus) { op.call }
    assert_raises(Minitest::Assertion) do
      assert_event_source(events, "test.happened", "WrongOpName")
    end
  end

  # ── capture_events uses global bus by default ─────────────────────────────────

  def test_capture_events_uses_global_registry_bus_when_no_bus_given
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events
      emits "global.test", on: :success
    end

    events = capture_events { op.call }
    assert_equal 1, events.size
    assert_equal "global.test", events.first.name
  end
end
