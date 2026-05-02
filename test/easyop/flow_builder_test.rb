# frozen_string_literal: true

require 'test_helper'

class FlowBuilderTest < Minitest::Test
  include EasyopTestHelper

  def make_flow(&call_block)
    klass = Class.new do
      include Easyop::Flow
      flow
    end
    # Redefine call on the inner operation step if needed
    klass
  end

  def make_flow_with_step(&step_call)
    step = Class.new { include Easyop::Operation }
    step.define_method(:call, &step_call) if step_call
    flow_klass = Class.new do
      include Easyop::Flow
    end
    flow_klass.flow(step)
    flow_klass
  end

  # ── on_success / on_failure callbacks ────────────────────────────────────────

  def test_on_success_fires_when_flow_succeeds
    f = make_flow_with_step { }
    called = false
    f.prepare.on_success { |_ctx| called = true }.call
    assert called
  end

  def test_on_success_does_not_fire_on_failure
    f = make_flow_with_step { ctx.fail! }
    called = false
    f.prepare.on_success { called = true }.call
    refute called
  end

  def test_on_failure_fires_when_flow_fails
    f = make_flow_with_step { ctx.fail!(error: 'bad') }
    called = false
    f.prepare.on_failure { |ctx| called = true }.call
    assert called
  end

  def test_on_failure_does_not_fire_on_success
    f = make_flow_with_step { }
    called = false
    f.prepare.on_failure { called = true }.call
    refute called
  end

  def test_multiple_success_callbacks_all_fire
    f = make_flow_with_step { }
    count = 0
    f.prepare.on_success { count += 1 }.on_success { count += 1 }.call
    assert_equal 2, count
  end

  # ── .call returns ctx ─────────────────────────────────────────────────────────

  def test_dot_call_returns_ctx
    f = make_flow_with_step { ctx[:x] = 7 }
    result = f.prepare.call
    assert_instance_of Easyop::Ctx, result
    assert_equal 7, result[:x]
  end

  # ── .on with method names ─────────────────────────────────────────────────────

  def test_on_success_symbol_with_bind_with
    f = make_flow_with_step { }
    binder = Object.new
    success_ctx = nil
    binder.define_singleton_method(:handle_ok) { |ctx| success_ctx = ctx }

    f.prepare.bind_with(binder).on(success: :handle_ok).call
    refute_nil success_ctx
  end

  def test_on_fail_symbol_with_bind_with
    f = make_flow_with_step { ctx.fail! }
    binder = Object.new
    fail_ctx = nil
    binder.define_singleton_method(:handle_fail) { |ctx| fail_ctx = ctx }

    f.prepare.bind_with(binder).on(fail: :handle_fail).call
    refute_nil fail_ctx
  end

  def test_on_symbol_without_bind_with_raises
    f = make_flow_with_step { }
    builder = f.prepare.on(success: :go)
    assert_raises(ArgumentError) { builder.call }
  end

  def test_on_symbol_arity_zero_method_called_without_arg
    f = make_flow_with_step { }
    binder = Object.new
    called = false
    binder.define_singleton_method(:done) { called = true }

    f.prepare.bind_with(binder).on(success: :done).call
    assert called
  end

  # ── .prepare returns a new builder each call ─────────────────────────────────

  def test_prepare_returns_a_flow_builder
    f = make_flow_with_step { }
    assert_instance_of Easyop::FlowBuilder, f.prepare
  end

  def test_prepare_returns_new_builder_each_time
    f = make_flow_with_step { }
    refute_same f.prepare, f.prepare
  end

  # ── multiple on_failure callbacks ─────────────────────────────────────────────

  def test_multiple_failure_callbacks_all_fire_in_order
    f = make_flow_with_step { ctx.fail! }
    log = []
    f.prepare.on_failure { log << :first }.on_failure { log << :second }.call
    assert_equal [:first, :second], log
  end

  # ── mixed on_success / on_failure ────────────────────────────────────────────

  def test_mixed_fires_only_success_callbacks_on_success
    f = make_flow_with_step { ctx[:v] = 7 }
    success_log = []
    failure_log = []
    f.prepare
     .on_success { |ctx| success_log << ctx[:v] }
     .on_failure { |ctx| failure_log << ctx.error }
     .call
    assert_equal [7], success_log
    assert_empty failure_log
  end

  def test_mixed_fires_only_failure_callbacks_on_failure
    f = make_flow_with_step { ctx.fail!(error: 'bad') }
    success_log = []
    failure_log = []
    f.prepare
     .on_success { success_log << :ok }
     .on_failure { |ctx| failure_log << ctx.error }
     .call
    assert_empty success_log
    assert_equal ['bad'], failure_log
  end

  # ── .call accepts initial attributes ─────────────────────────────────────────

  def test_call_accepts_initial_attributes
    step = Class.new { include Easyop::Operation }
    step.define_method(:call) { ctx[:output] = ctx[:input] * 3 }
    flow_klass = Class.new { include Easyop::Flow }
    flow_klass.flow(step)
    ctx = flow_klass.prepare.call(input: 5)
    assert_equal 15, ctx[:output]
  end

  # ── on with both success: and fail: in single call ───────────────────────────

  def test_on_supports_both_success_and_fail_in_single_call
    success_received = nil
    fail_received    = nil
    target = Object.new
    target.define_singleton_method(:on_ok)   { |ctx| success_received = ctx[:v] }
    target.define_singleton_method(:on_fail) { |ctx| fail_received    = ctx.error }

    make_flow_with_step { ctx[:v] = 7 }
      .prepare.bind_with(target).on(success: :on_ok, fail: :on_fail).call
    assert_equal 7, success_received
    assert_nil fail_received

    fail_received = nil
    make_flow_with_step { ctx.fail!(error: 'err') }
      .prepare.bind_with(target).on(success: :on_ok, fail: :on_fail).call
    assert_equal 'err', fail_received
  end

  # ── ctx.slice ─────────────────────────────────────────────────────────────────

  def test_ctx_slice_returns_only_requested_keys
    ctx = Easyop::Ctx.new(name: 'Alice', email: 'alice@example.com', age: 30)
    assert_equal({ name: 'Alice', email: 'alice@example.com' }, ctx.slice(:name, :email))
  end

  def test_ctx_slice_excludes_unrequested_keys
    ctx = Easyop::Ctx.new(name: 'Alice', age: 30)
    assert_equal({ name: 'Alice' }, ctx.slice(:name))
  end

  def test_ctx_slice_ignores_missing_keys
    ctx = Easyop::Ctx.new(name: 'Alice')
    assert_equal({ name: 'Alice' }, ctx.slice(:name, :missing))
  end

  def test_ctx_slice_returns_empty_hash_when_no_keys_match
    ctx = Easyop::Ctx.new(name: 'Alice')
    assert_equal({}, ctx.slice(:x, :y))
  end

  # ── chaining returns self ─────────────────────────────────────────────────────

  def test_on_success_returns_builder_for_chaining
    f = make_flow_with_step { }
    builder = f.prepare
    assert_same builder, builder.on_success { }
  end

  def test_on_failure_returns_builder_for_chaining
    f = make_flow_with_step { }
    builder = f.prepare
    assert_same builder, builder.on_failure { }
  end

  def test_bind_with_returns_builder_for_chaining
    f = make_flow_with_step { }
    builder = f.prepare
    assert_same builder, builder.bind_with(Object.new)
  end
end
