# frozen_string_literal: true

require 'test_helper'

# ActiveSupport::Notifications is stubbed in test_helper.rb.

class PluginsInstrumentationTest < Minitest::Test
  include EasyopTestHelper

  EVENT = Easyop::Plugins::Instrumentation::EVENT

  def setup
    super
    ActiveSupport::Notifications.reset! if ActiveSupport::Notifications.respond_to?(:reset!)
    @received = []
    ActiveSupport::Notifications.subscribe(EVENT) do |_name, _s, _f, _id, payload|
      @received << payload.dup
    end
  end

  def teardown
    ActiveSupport::Notifications.reset! if ActiveSupport::Notifications.respond_to?(:reset!)
    super
  end

  def make_op(&call_block)
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Instrumentation
    end
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  # ── Event fired on success ────────────────────────────────────────────────────

  def test_fires_event_on_success
    op = make_op { ctx[:ok] = true }
    op.call
    assert_equal 1, @received.size
  end

  def test_event_payload_success_true_on_success
    op = make_op { }
    op.call
    assert_equal true, @received.first[:success]
  end

  def test_event_payload_error_nil_on_success
    op = make_op { }
    op.call
    assert_nil @received.first[:error]
  end

  def test_event_payload_duration_is_float
    op = make_op { }
    op.call
    assert_instance_of Float, @received.first[:duration]
  end

  def test_event_payload_ctx_is_easyop_ctx
    op = make_op { }
    op.call
    assert_instance_of Easyop::Ctx, @received.first[:ctx]
  end

  # ── Event fired on failure ────────────────────────────────────────────────────

  def test_fires_event_on_failure
    op = make_op { ctx.fail!(error: 'oops') }
    op.call
    assert_equal 1, @received.size
    assert_equal false, @received.first[:success]
    assert_equal 'oops', @received.first[:error]
  end

  # ── Inheritance ───────────────────────────────────────────────────────────────

  def test_subclass_inherits_instrumentation
    base = make_op { }
    child = Class.new(base) do
      define_method(:call) { ctx[:child] = true }
    end
    child.call
    assert_equal 1, @received.size
  end
end
