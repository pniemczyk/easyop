# frozen_string_literal: true

require 'test_helper'

class BusMemoryTest < Minitest::Test
  include EasyopTestHelper

  def bus
    @bus ||= Easyop::Events::Bus::Memory.new
  end

  def event(name = 'order.placed', payload = {})
    Easyop::Events::Event.new(name: name, payload: payload)
  end

  # ── publish / subscribe ───────────────────────────────────────────────────────

  def test_subscribe_and_publish_delivers_event
    received = []
    bus.subscribe('order.placed') { |e| received << e.name }
    bus.publish(event('order.placed'))
    assert_equal ['order.placed'], received
  end

  def test_publish_does_not_deliver_to_non_matching_subscriber
    received = []
    bus.subscribe('order.shipped') { |e| received << e.name }
    bus.publish(event('order.placed'))
    assert_empty received
  end

  def test_multiple_subscribers_same_pattern_all_called
    count = 0
    bus.subscribe('evt') { count += 1 }
    bus.subscribe('evt') { count += 1 }
    bus.publish(event('evt'))
    assert_equal 2, count
  end

  # ── Glob patterns ─────────────────────────────────────────────────────────────

  def test_single_star_matches_one_segment
    received = []
    bus.subscribe('order.*') { |e| received << e.name }
    bus.publish(event('order.placed'))
    bus.publish(event('order.shipped'))
    assert_equal ['order.placed', 'order.shipped'], received
  end

  def test_single_star_does_not_match_nested_segments
    received = []
    bus.subscribe('order.*') { |e| received << e.name }
    bus.publish(event('order.payment.failed'))
    assert_empty received
  end

  def test_double_star_matches_any_depth
    received = []
    bus.subscribe('order.**') { |e| received << e.name }
    bus.publish(event('order.placed'))
    bus.publish(event('order.payment.failed'))
    bus.publish(event('order.a.b.c'))
    assert_equal 3, received.size
  end

  def test_double_star_wildcard_matches_all_events
    received = []
    bus.subscribe('**') { |e| received << e.name }
    bus.publish(event('anything'))
    bus.publish(event('order.placed'))
    assert_equal 2, received.size
  end

  def test_regexp_pattern
    received = []
    bus.subscribe(/\Aorder\..+\z/) { |e| received << e.name }
    bus.publish(event('order.placed'))
    bus.publish(event('user.created'))
    assert_equal ['order.placed'], received
  end

  # ── unsubscribe ───────────────────────────────────────────────────────────────

  def test_unsubscribe_removes_handler
    received = []
    handle = bus.subscribe('evt') { |e| received << e.name }
    bus.unsubscribe(handle)
    bus.publish(event('evt'))
    assert_empty received
  end

  # ── clear! ───────────────────────────────────────────────────────────────────

  def test_clear_removes_all_subscribers
    bus.subscribe('a') { }
    bus.subscribe('b') { }
    assert_equal 2, bus.subscriber_count
    bus.clear!
    assert_equal 0, bus.subscriber_count
  end

  # ── Handler failures don't prevent other handlers ────────────────────────────

  def test_publish_continues_after_handler_exception
    second_called = false
    bus.subscribe('evt') { raise 'boom' }
    bus.subscribe('evt') { second_called = true }
    bus.publish(event('evt'))
    assert second_called
  end

  # ── subscriber_count ─────────────────────────────────────────────────────────

  def test_subscriber_count_reflects_active_subscriptions
    assert_equal 0, bus.subscriber_count
    bus.subscribe('x') { }
    assert_equal 1, bus.subscriber_count
  end
end
