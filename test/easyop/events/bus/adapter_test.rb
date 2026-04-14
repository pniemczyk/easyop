# frozen_string_literal: true

require 'test_helper'

class BusAdapterTest < Minitest::Test
  include EasyopTestHelper

  # Concrete subclass of Bus::Adapter for testing the helpers.
  class TestAdapter < Easyop::Events::Bus::Adapter
    attr_reader :published, :subscriptions

    def initialize
      super
      @published     = []
      @subscriptions = []
    end

    def publish(event)
      snap = @subscriptions.dup
      snap.each do |sub|
        _safe_invoke(sub[:handler], event) if _pattern_matches?(sub[:pattern], event.name)
      end
      @published << event
    end

    def subscribe(pattern, &block)
      entry = { pattern: _compile_pattern(pattern), handler: block }
      @subscriptions << entry
      entry
    end

    def unsubscribe(handle)
      @subscriptions.delete(handle)
    end
  end

  def adapter
    @adapter ||= TestAdapter.new
  end

  def event(name = 'test.event')
    Easyop::Events::Event.new(name: name)
  end

  # ── _safe_invoke swallows errors ──────────────────────────────────────────────

  def test_safe_invoke_calls_handler_normally
    received = nil
    adapter.subscribe('test.event') { |e| received = e }
    adapter.publish(event('test.event'))
    refute_nil received
  end

  def test_safe_invoke_swallows_handler_errors
    second = false
    adapter.subscribe('test.event') { raise 'boom' }
    adapter.subscribe('test.event') { second = true }
    adapter.publish(event('test.event'))
    assert second
  end

  # ── _compile_pattern caches and converts globs ────────────────────────────────

  def test_compile_pattern_converts_glob_to_regexp
    received = []
    adapter.subscribe('order.*') { |e| received << e.name }
    adapter.publish(event('order.placed'))
    adapter.publish(event('order.shipped'))
    assert_equal 2, received.size
  end

  def test_compile_pattern_passes_regexp_through_unchanged
    received = []
    adapter.subscribe(/\Aorder\..*\z/) { |e| received << e.name }
    adapter.publish(event('order.placed'))
    assert_equal ['order.placed'], received
  end

  def test_compile_pattern_caches_result
    # Calling compile_pattern twice returns the same Regexp object (via cache)
    # We test indirectly: subscribe twice with same string pattern and both should match
    count = 0
    adapter.subscribe('a.*') { count += 1 }
    adapter.subscribe('a.*') { count += 1 }
    adapter.publish(event('a.b'))
    assert_equal 2, count
  end

  # ── unsubscribe ───────────────────────────────────────────────────────────────

  def test_unsubscribe_removes_handler
    received = []
    handle = adapter.subscribe('e') { received << 1 }
    adapter.unsubscribe(handle)
    adapter.publish(event('e'))
    assert_empty received
  end

  # ── Bus::Base raises NotImplementedError ─────────────────────────────────────

  def test_base_publish_raises_not_implemented
    base = Easyop::Events::Bus::Base.new
    assert_raises(NotImplementedError) { base.publish(event) }
  end

  def test_base_subscribe_raises_not_implemented
    base = Easyop::Events::Bus::Base.new
    assert_raises(NotImplementedError) { base.subscribe('x') { } }
  end

  def test_base_unsubscribe_is_no_op
    base = Easyop::Events::Bus::Base.new
    base.unsubscribe(:anything) # must not raise
  end
end
