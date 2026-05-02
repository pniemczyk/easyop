# frozen_string_literal: true

require 'test_helper'

class PluginsEventsTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    Easyop::Events::Registry.reset!
  end

  def teardown
    Easyop::Events::Registry.reset!
    super
  end

  def make_op(bus: nil, &call_block)
    opts = bus ? { bus: bus } : {}
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events, **opts
    end
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  def capture_events(bus = nil)
    bus ||= Easyop::Events::Registry.bus
    events = []
    bus.subscribe('**') { |e| events << e }
    events
  end

  # ── emits on :success ─────────────────────────────────────────────────────────

  def test_emits_success_fires_after_successful_call
    events = capture_events
    op = make_op { }
    op.emits 'order.placed', on: :success
    op.call
    assert_equal 1, events.size
    assert_equal 'order.placed', events.first.name
  end

  def test_emits_success_does_not_fire_on_failure
    events = capture_events
    op = make_op { ctx.fail! }
    op.emits 'order.placed', on: :success
    op.call
    assert_empty events
  end

  # ── emits on :failure ─────────────────────────────────────────────────────────

  def test_emits_failure_fires_after_failed_call
    events = capture_events
    op = make_op { ctx.fail!(error: 'bad') }
    op.emits 'order.failed', on: :failure
    op.call
    assert_equal 1, events.size
    assert_equal 'order.failed', events.first.name
  end

  def test_emits_failure_does_not_fire_on_success
    events = capture_events
    op = make_op { }
    op.emits 'order.failed', on: :failure
    op.call
    assert_empty events
  end

  # ── emits on :always ──────────────────────────────────────────────────────────

  def test_emits_always_fires_on_success
    events = capture_events
    op = make_op { }
    op.emits 'op.attempted', on: :always
    op.call
    assert_equal 1, events.size
  end

  def test_emits_always_fires_on_failure
    events = capture_events
    op = make_op { ctx.fail! }
    op.emits 'op.attempted', on: :always
    op.call
    assert_equal 1, events.size
  end

  # ── payload options ───────────────────────────────────────────────────────────

  def test_payload_nil_uses_full_ctx_to_h
    events = capture_events
    op = make_op { ctx[:x] = 1; ctx[:y] = 2 }
    op.emits 'ev', on: :success, payload: nil
    op.call
    assert_equal({ x: 1, y: 2 }, events.first.payload)
  end

  def test_payload_array_slices_ctx
    events = capture_events
    op = make_op { ctx[:a] = 10; ctx[:b] = 20; ctx[:c] = 30 }
    op.emits 'ev', on: :success, payload: [:a, :c]
    op.call
    assert_equal({ a: 10, c: 30 }, events.first.payload)
  end

  def test_payload_proc_receives_ctx
    events = capture_events
    op = make_op { ctx[:val] = 99 }
    op.emits 'ev', on: :success, payload: ->(ctx) { { doubled: ctx[:val] * 2 } }
    op.call
    assert_equal({ doubled: 198 }, events.first.payload)
  end

  # ── guard ────────────────────────────────────────────────────────────────────

  def test_guard_prevents_event_when_falsy
    events = capture_events
    op = make_op { ctx[:fire] = false }
    op.emits 'ev', on: :always, guard: ->(ctx) { ctx[:fire] }
    op.call
    assert_empty events
  end

  def test_guard_allows_event_when_truthy
    events = capture_events
    op = make_op { ctx[:fire] = true }
    op.emits 'ev', on: :always, guard: ->(ctx) { ctx[:fire] }
    op.call
    assert_equal 1, events.size
  end

  # ── source ────────────────────────────────────────────────────────────────────

  def test_event_source_is_operation_class_name
    events = capture_events
    op = make_op { }
    op.emits 'ev', on: :always
    set_const('SourceTestOp', op)
    op.call
    assert_equal 'SourceTestOp', events.first.source
  end

  # ── metadata ─────────────────────────────────────────────────────────────────

  def test_hash_metadata_from_plugin_option
    events = capture_events
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events, metadata: { env: 'test' }
      emits 'ev', on: :always
    end
    klass.call
    assert_equal({ env: 'test' }, events.first.metadata)
  end

  def test_proc_metadata_receives_ctx
    events = capture_events
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events, metadata: ->(ctx) { { x: ctx[:x] } }
      emits 'ev', on: :always
    end
    klass.call(x: 7)
    assert_equal({ x: 7 }, events.first.metadata)
  end

  # ── per-class bus override ────────────────────────────────────────────────────

  def test_per_class_bus_receives_events
    custom_bus = Easyop::Events::Bus::Memory.new
    custom_events = []
    custom_bus.subscribe('**') { |e| custom_events << e }

    op = make_op(bus: custom_bus) { }
    op.emits 'ev', on: :always
    op.call

    assert_equal 1, custom_events.size
    assert_empty capture_events  # global registry bus received nothing
  end

  # ── Inheritance ───────────────────────────────────────────────────────────────

  def test_child_inherits_parent_emits
    events = capture_events
    parent = make_op { }
    parent.emits 'parent.event', on: :always

    child = Class.new(parent) { define_method(:call) { } }
    child.call
    assert_equal 1, events.size
    assert_equal 'parent.event', events.first.name
  end

  def test_child_emits_do_not_affect_parent_events_list
    parent = make_op { }
    parent.emits 'parent.event', on: :always

    child = Class.new(parent) { define_method(:call) { } }
    child.emits 'child.event', on: :always

    # Parent's declared emits list must not be mutated by child additions.
    assert_equal 1, parent._emitted_events.size
    assert_equal 'parent.event', parent._emitted_events.first[:name]

    # Child inherits parent's event AND adds its own.
    assert_equal 2, child._emitted_events.size
    assert_equal 'child.event', child._emitted_events.last[:name]
  end

  # ── Event ordering — fires AFTER call body ───────────────────────────────────

  def test_events_fire_after_operation_call_completes
    order  = []
    op     = make_op { order << :call }
    op.emits 'order.placed', on: :success
    Easyop::Events::Registry.bus.subscribe('order.placed') { |_e| order << :event }
    op.call
    assert_equal [:call, :event], order
  end

  def test_events_fire_even_when_call_bang_raises_ctx_failure
    published = []
    Easyop::Events::Registry.bus.subscribe('order.failed') { |e| published << e }
    op = make_op { ctx.fail! }
    op.emits 'order.failed', on: :failure
    assert_raises(Easyop::Ctx::Failure) { op.call! }
    assert_equal 1, published.size
  end

  # ── Publish failure does not crash operation ──────────────────────────────────

  def test_publish_failure_does_not_crash_operation
    # Bus that raises on publish
    bad_bus = Object.new
    bad_bus.define_singleton_method(:publish)   { |_e| raise 'bus error' }
    bad_bus.define_singleton_method(:subscribe) { |_p, &_b| }

    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events, bus: Easyop::Events::Bus::Custom.new(bad_bus)
      emits 'ev', on: :always
    end
    result = op.call
    assert_predicate result, :success?
  end
end
