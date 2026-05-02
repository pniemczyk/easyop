# frozen_string_literal: true

require 'test_helper'

class RegistryTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    Easyop::Events::Registry.reset!
  end

  def teardown
    Easyop::Events::Registry.reset!
    super
  end

  # ── bus= / bus ───────────────────────────────────────────────────────────────

  def test_dot_bus_defaults_to_memory_instance
    assert_instance_of Easyop::Events::Bus::Memory, Easyop::Events::Registry.bus
  end

  def test_dot_bus_setter_with_symbol_memory
    Easyop::Events::Registry.bus = :memory
    assert_instance_of Easyop::Events::Bus::Memory, Easyop::Events::Registry.bus
  end

  def test_dot_bus_setter_with_bus_base_subclass
    custom_bus = Easyop::Events::Bus::Memory.new
    Easyop::Events::Registry.bus = custom_bus
    assert_same custom_bus, Easyop::Events::Registry.bus
  end

  def test_dot_bus_setter_with_custom_adapter_object
    adapter = Object.new
    adapter.define_singleton_method(:publish)   { |e|         }
    adapter.define_singleton_method(:subscribe) { |p, &b|     }

    Easyop::Events::Registry.bus = adapter
    assert_instance_of Easyop::Events::Bus::Custom, Easyop::Events::Registry.bus
  end

  def test_dot_bus_setter_raises_for_unknown_value
    assert_raises(ArgumentError) { Easyop::Events::Registry.bus = :unknown_bus }
  end

  def test_dot_bus_setter_raises_for_object_without_publish_subscribe
    assert_raises(ArgumentError) { Easyop::Events::Registry.bus = Object.new }
  end

  # ── register_handler ──────────────────────────────────────────────────────────

  def test_dot_register_handler_records_subscription
    handler = Class.new { include Easyop::Operation }
    Easyop::Events::Registry.register_handler(
      pattern:       'order.placed',
      handler_class: handler,
      async:         false
    )
    subs = Easyop::Events::Registry.subscriptions
    assert_equal 1, subs.size
    assert_equal 'order.placed', subs.first[:pattern]
    assert_equal handler,        subs.first[:handler_class]
  end

  def test_dot_register_handler_dispatches_sync_on_publish
    received = []
    handler = Class.new do
      include Easyop::Operation
      define_method(:call) { received << ctx[:event].name }
    end
    Easyop::Events::Registry.register_handler(
      pattern:       'order.placed',
      handler_class: handler,
      async:         false
    )
    evt = Easyop::Events::Event.new(name: 'order.placed', payload: { x: 1 })
    Easyop::Events::Registry.bus.publish(evt)
    assert_equal ['order.placed'], received
  end

  def test_dot_register_handler_merges_payload_into_ctx
    received_ctx = nil
    handler = Class.new do
      include Easyop::Operation
      define_method(:call) { received_ctx = ctx }
    end
    Easyop::Events::Registry.register_handler(
      pattern:       'order.placed',
      handler_class: handler,
      async:         false
    )
    evt = Easyop::Events::Event.new(name: 'order.placed', payload: { order_id: 99 })
    Easyop::Events::Registry.bus.publish(evt)
    assert_equal 99, received_ctx[:order_id]
  end

  # ── reset! ────────────────────────────────────────────────────────────────────

  def test_dot_reset_clears_subscriptions_and_bus
    handler = Class.new { include Easyop::Operation }
    Easyop::Events::Registry.register_handler(pattern: 'x', handler_class: handler)
    Easyop::Events::Registry.reset!
    assert_empty Easyop::Events::Registry.subscriptions
  end

  def test_dot_reset_replaces_bus_with_fresh_memory_instance
    old_bus = Easyop::Events::Registry.bus
    Easyop::Events::Registry.reset!
    new_bus = Easyop::Events::Registry.bus
    refute_same old_bus, new_bus
    assert_instance_of Easyop::Events::Bus::Memory, new_bus
  end

  # ── _dispatch swallows handler errors ─────────────────────────────────────────

  def test_dot_dispatch_swallows_handler_exception
    handler = Class.new do
      include Easyop::Operation
      define_method(:call) { raise 'handler exploded' }
    end
    Easyop::Events::Registry.register_handler(
      pattern:       'x',
      handler_class: handler,
      async:         false
    )
    evt = Easyop::Events::Event.new(name: 'x')
    # Must not raise
    Easyop::Events::Registry.bus.publish(evt)
  end

  # ── _dispatch with async: true ───────────────────────────────────────────────

  def test_dispatch_calls_call_async_when_async_true_and_available
    enqueued = []
    handler  = Class.new { include Easyop::Operation; def call; end }
    handler.define_singleton_method(:call_async) { |attrs, **_opts| enqueued << attrs }

    entry = { handler_class: handler, async: true, options: {} }
    evt   = Easyop::Events::Event.new(name: 'order.placed', payload: { order_id: 7 })
    Easyop::Events::Registry.send(:_dispatch, evt, entry)

    assert_equal 1, enqueued.size
    assert_equal 7, enqueued.first[:order_id]
    assert_kind_of Hash, enqueued.first[:event_data]
  end

  def test_dispatch_falls_back_to_sync_when_call_async_unavailable
    calls   = []
    handler = Class.new do
      include Easyop::Operation
      define_method(:call) { calls << :sync }
    end

    entry = { handler_class: handler, async: true, options: {} }
    evt   = Easyop::Events::Event.new(name: 'order.placed')
    Easyop::Events::Registry.send(:_dispatch, evt, entry)

    assert_equal [:sync], calls
  end

  def test_dispatch_passes_queue_option_to_call_async
    received_opts = {}
    handler = Class.new { include Easyop::Operation; def call; end }
    handler.define_singleton_method(:call_async) { |_attrs, **opts| received_opts.merge!(opts) }

    entry = { handler_class: handler, async: true, options: { queue: 'low' } }
    evt   = Easyop::Events::Event.new(name: 'order.placed')
    Easyop::Events::Registry.send(:_dispatch, evt, entry)

    assert_equal 'low', received_opts[:queue]
  end

  # ── active_support bus symbol ─────────────────────────────────────────────────

  def test_dot_bus_setter_with_symbol_active_support_creates_as_adapter
    # AS may or may not be defined in this test env — we just check it doesn't
    # crash if AS::Notifications is defined, or raises LoadError if absent.
    if defined?(::ActiveSupport::Notifications)
      Easyop::Events::Registry.bus = :active_support
      assert_instance_of Easyop::Events::Bus::ActiveSupportNotifications,
                         Easyop::Events::Registry.bus
    else
      # Even creating the adapter is OK until publish/subscribe is called
      Easyop::Events::Registry.bus = :active_support
      assert_instance_of Easyop::Events::Bus::ActiveSupportNotifications,
                         Easyop::Events::Registry.bus
    end
  end
end
