# frozen_string_literal: true

require 'test_helper'

class BusCustomTest < Minitest::Test
  include EasyopTestHelper

  def make_adapter(publish: true, subscribe: true, unsubscribe: false)
    obj = Object.new
    obj.define_singleton_method(:publish)   { |e|          } if publish
    obj.define_singleton_method(:subscribe) { |pat, &blk|  } if subscribe
    obj.define_singleton_method(:unsubscribe) { |h|        } if unsubscribe
    obj
  end

  # ── Construction ─────────────────────────────────────────────────────────────

  def test_dot_new_accepts_valid_adapter
    adapter = make_adapter
    custom = Easyop::Events::Bus::Custom.new(adapter)
    assert_instance_of Easyop::Events::Bus::Custom, custom
  end

  def test_dot_new_raises_when_adapter_missing_publish
    adapter = make_adapter(publish: false)
    assert_raises(ArgumentError) { Easyop::Events::Bus::Custom.new(adapter) }
  end

  def test_dot_new_raises_when_adapter_missing_subscribe
    adapter = make_adapter(subscribe: false)
    assert_raises(ArgumentError) { Easyop::Events::Bus::Custom.new(adapter) }
  end

  def test_dot_new_error_message_includes_adapter_inspect
    bad = Object.new
    err = assert_raises(ArgumentError) { Easyop::Events::Bus::Custom.new(bad) }
    assert_includes err.message, bad.inspect
  end

  # ── Delegation ───────────────────────────────────────────────────────────────

  def test_publish_delegates_to_adapter
    published = []
    adapter = make_adapter
    adapter.define_singleton_method(:publish) { |e| published << e }

    custom = Easyop::Events::Bus::Custom.new(adapter)
    evt = Easyop::Events::Event.new(name: 'x')
    custom.publish(evt)
    assert_equal [evt], published
  end

  def test_subscribe_delegates_to_adapter
    subscribed = []
    adapter = make_adapter
    adapter.define_singleton_method(:subscribe) { |pat, &blk| subscribed << pat }

    custom = Easyop::Events::Bus::Custom.new(adapter)
    custom.subscribe('order.*') { }
    assert_equal ['order.*'], subscribed
  end

  def test_unsubscribe_delegates_when_adapter_supports_it
    removed = []
    adapter = make_adapter(unsubscribe: true)
    adapter.define_singleton_method(:unsubscribe) { |h| removed << h }

    custom = Easyop::Events::Bus::Custom.new(adapter)
    custom.unsubscribe(:handle)
    assert_equal [:handle], removed
  end

  def test_unsubscribe_is_no_op_when_adapter_does_not_support_it
    adapter = make_adapter(unsubscribe: false)
    custom = Easyop::Events::Bus::Custom.new(adapter)
    custom.unsubscribe(:handle) # must not raise
  end
end
