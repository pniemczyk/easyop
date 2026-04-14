# frozen_string_literal: true

require 'test_helper'

class PluginsEventHandlersTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    Easyop::Events::Registry.reset!
  end

  def teardown
    Easyop::Events::Registry.reset!
    super
  end

  def publish(name, payload = {})
    evt = Easyop::Events::Event.new(name: name, payload: payload, source: 'Publisher')
    Easyop::Events::Registry.bus.publish(evt)
  end

  def make_handler(pattern, async: false, &call_block)
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::EventHandlers
    end
    klass.on(pattern, async: async)
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  # ── Basic dispatch ────────────────────────────────────────────────────────────

  def test_handler_called_when_matching_event_published
    received = []
    make_handler('order.placed') { received << ctx.event.name }
    publish('order.placed')
    assert_equal ['order.placed'], received
  end

  def test_handler_not_called_for_non_matching_event
    received = []
    make_handler('order.placed') { received << ctx.event.name }
    publish('order.shipped')
    assert_empty received
  end

  # ── ctx.event and payload ─────────────────────────────────────────────────────

  def test_ctx_event_is_easyop_event_instance
    received_event = nil
    make_handler('ev') { received_event = ctx.event }
    publish('ev')
    assert_instance_of Easyop::Events::Event, received_event
    assert_equal 'ev', received_event.name
  end

  def test_payload_keys_merged_into_ctx
    received = {}
    make_handler('ev') { received = ctx.slice(:order_id, :total) }
    publish('ev', order_id: 42, total: 999)
    assert_equal({ order_id: 42, total: 999 }, received)
  end

  def test_ctx_hash_style_access_safe_for_absent_payload_keys
    received = nil
    make_handler('ev') { received = ctx[:missing] }
    publish('ev', present: true)
    assert_nil received
  end

  # ── Glob patterns ─────────────────────────────────────────────────────────────

  def test_single_star_pattern_matches_one_segment
    received = []
    make_handler('order.*') { received << ctx.event.name }
    publish('order.placed')
    publish('order.shipped')
    publish('order.payment.failed')  # should NOT match
    assert_equal 2, received.size
  end

  def test_double_star_pattern_matches_any_depth
    received = []
    make_handler('order.**') { received << ctx.event.name }
    publish('order.placed')
    publish('order.payment.failed')
    assert_equal 2, received.size
  end

  def test_double_star_wildcard_matches_all
    received = []
    make_handler('**') { received << ctx.event.name }
    publish('anything')
    publish('order.placed')
    assert_equal 2, received.size
  end

  # ── Multiple `on` declarations ────────────────────────────────────────────────

  def test_multiple_on_declarations_registered_independently
    received = []
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::EventHandlers
    end
    klass.on('a.event')
    klass.on('b.event')
    klass.define_method(:call) { received << ctx.event.name }

    publish('a.event')
    publish('b.event')
    assert_equal 2, received.size
  end

  # ── _event_handler_registrations ──────────────────────────────────────────────

  def test_event_handler_registrations_recorded
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::EventHandlers
    end
    klass.on('order.*')
    klass.on('user.created')
    assert_equal 2, klass._event_handler_registrations.size
    assert_equal 'order.*',     klass._event_handler_registrations[0][:pattern]
    assert_equal 'user.created', klass._event_handler_registrations[1][:pattern]
  end

  # ── Handler exception swallowed ───────────────────────────────────────────────

  def test_handler_exception_does_not_propagate_to_publisher
    make_handler('ev') { raise 'handler crash' }
    publish('ev') # must not raise
  end

  def test_second_handler_runs_after_first_handler_fails
    second_called = false
    make_handler('ev') { raise 'crash' }
    make_handler('ev') { second_called = true }
    publish('ev')
    assert second_called
  end

  # ── Async dispatch ────────────────────────────────────────────────────────────

  def test_async_handler_calls_call_async_if_available
    enqueued = []
    async_handler = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::EventHandlers

      define_singleton_method(:call_async) { |attrs, **opts| enqueued << { attrs: attrs, opts: opts } }
    end
    async_handler.on('order.placed', async: true)

    publish('order.placed', order_id: 1)
    assert_equal 1, enqueued.size
    assert enqueued.first[:attrs].key?(:event_data)
  end

  def test_async_handler_includes_payload_keys_in_attrs
    enqueued = []
    async_handler = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::EventHandlers
      define_singleton_method(:call_async) { |attrs, **_opts| enqueued << attrs }
    end
    async_handler.on('order.placed', async: true)

    publish('order.placed', order_id: 42)
    assert_equal 42, enqueued.first[:order_id]
  end

  def test_async_handler_passes_queue_option
    enqueued = []
    async_handler = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::EventHandlers
      define_singleton_method(:call_async) { |attrs, **opts| enqueued << opts }
    end
    async_handler.on('ev', async: true, queue: 'low')

    publish('ev')
    assert_equal 'low', enqueued.first[:queue]
  end
end
