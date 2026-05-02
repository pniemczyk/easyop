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
    @_as_sub = ActiveSupport::Notifications.subscribe(EVENT) do |_name, _s, _f, _id, payload|
      @received << payload.dup
    end
    @_log_subs = []
  end

  def teardown
    # Unsubscribe per-test subscribers so they don't pollute subsequent tests
    # when the real AS is active (its registry ignores our stub reset!).
    ActiveSupport::Notifications.unsubscribe(@_as_sub) if @_as_sub rescue nil
    @_log_subs.each { |s| ActiveSupport::Notifications.unsubscribe(s) rescue nil }
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

  # ── Event payload: operation name ─────────────────────────────────────────────

  def test_event_payload_operation_is_class_name
    op = make_op { }
    set_const('InstrOpNameMT', op)
    Object.const_get('InstrOpNameMT').call
    assert_equal 'InstrOpNameMT', @received.first[:operation]
  end

  # ── Event payload: ctx is the same object returned by .call ──────────────────

  def test_event_payload_ctx_is_same_object_as_return_value
    op = make_op { }
    result = op.call
    assert_same result, @received.first[:ctx]
  end

  # ── Failed call: duration is positive ────────────────────────────────────────

  def test_event_payload_duration_positive_on_failure
    op = make_op { ctx.fail!(error: 'oops') }
    op.call
    assert_operator @received.first[:duration], :>=, 0
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

  def test_subclass_payload_success_true
    base = make_op { }
    child = Class.new(base) { define_method(:call) { ctx[:x] = 1 } }
    child.call
    assert_equal true, @received.first[:success]
  end

  # ── Multiple operations fire separate events ──────────────────────────────────

  def test_multiple_operations_each_fire_separate_event_with_own_name
    op_a = make_op { }
    op_b = make_op { }
    set_const('InstrMTOpA', op_a)
    set_const('InstrMTOpB', op_b)
    Object.const_get('InstrMTOpA').call
    Object.const_get('InstrMTOpB').call
    assert_equal 2, @received.size
    names = @received.map { |p| p[:operation] }
    assert_includes names, 'InstrMTOpA'
    assert_includes names, 'InstrMTOpB'
  end

  # ── RunWrapper is prepended ───────────────────────────────────────────────────

  def test_run_wrapper_prepended_to_ancestors
    op = make_op { }
    assert_includes op.ancestors, Easyop::Plugins::Instrumentation::RunWrapper
  end

  # ── attach_log_subscriber ─────────────────────────────────────────────────────

  def test_attach_log_subscriber_logs_info_on_success
    infos = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:info)  { |msg| infos << msg }
    fake_logger.define_singleton_method(:warn)  { |_msg| }

    rails_mod = Module.new do
      define_singleton_method(:logger) { fake_logger }
      def self.respond_to?(m, *_); m == :logger || super; end
    end
    set_const('Rails', rails_mod)

    op = make_op { }
    set_const('InstrLogSuccessMT', op)
    @_log_subs << Easyop::Plugins::Instrumentation.attach_log_subscriber
    Object.const_get('InstrLogSuccessMT').call
    refute_empty infos
  end

  def test_attach_log_subscriber_logs_warn_on_failure
    warns = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:info) { |_msg| }
    fake_logger.define_singleton_method(:warn) { |msg| warns << msg }

    rails_mod = Module.new do
      define_singleton_method(:logger) { fake_logger }
      def self.respond_to?(m, *_); m == :logger || super; end
    end
    set_const('Rails', rails_mod)

    op = make_op { ctx.fail!(error: 'oops') }
    set_const('InstrLogFailMT', op)
    @_log_subs << Easyop::Plugins::Instrumentation.attach_log_subscriber
    Object.const_get('InstrLogFailMT').call
    refute_empty warns
  end
end
