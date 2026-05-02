# frozen_string_literal: true

require 'test_helper'

class FlowTest < Minitest::Test
  include EasyopTestHelper

  def make_step(name, &call_block)
    klass = Class.new do
      include Easyop::Operation
    end
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  def make_flow(*steps)
    steps_copy = steps
    Class.new do
      include Easyop::Flow
      flow(*steps_copy)
    end
  end

  # ── Basic execution ───────────────────────────────────────────────────────────

  def test_dot_call_runs_all_steps_in_order
    order = []
    s1 = make_step(:s1) { order << 1 }
    s2 = make_step(:s2) { order << 2 }
    f = make_flow(s1, s2)
    f.call
    assert_equal [1, 2], order
  end

  def test_dot_call_returns_success_ctx_when_all_steps_succeed
    s1 = make_step(:s1) { ctx[:a] = 1 }
    s2 = make_step(:s2) { ctx[:b] = 2 }
    f = make_flow(s1, s2)
    result = f.call
    assert_predicate result, :success?
    assert_equal 1, result[:a]
    assert_equal 2, result[:b]
  end

  # ── Halting on failure ────────────────────────────────────────────────────────

  def test_dot_call_halts_after_failing_step
    ran = []
    s1 = make_step(:s1) { ran << :s1; ctx.fail!(error: 'bad') }
    s2 = make_step(:s2) { ran << :s2 }
    f = make_flow(s1, s2)
    result = f.call
    assert_predicate result, :failure?
    assert_equal [:s1], ran
  end

  def test_dot_call_returns_failed_ctx_on_step_failure
    s1 = make_step(:s1) { ctx.fail!(error: 'fail') }
    f = make_flow(s1)
    result = f.call
    assert_equal 'fail', result.error
  end

  # ── Rollback ──────────────────────────────────────────────────────────────────

  def test_dot_call_rolls_back_completed_steps_in_reverse
    rolled = []
    s1 = make_step(:s1) { }
    s1.define_method(:rollback) { rolled << :s1 }

    s2 = make_step(:s2) { ctx.fail! }

    f = make_flow(s1, s2)
    f.call
    assert_equal [:s1], rolled
  end

  def test_dot_call_bang_raises_on_failure
    s1 = make_step(:s1) { ctx.fail!(error: 'oops') }
    f = make_flow(s1)
    assert_raises(Easyop::Ctx::Failure) { f.call! }
  end

  # ── Lambda guards ─────────────────────────────────────────────────────────────

  def test_flow_lambda_guard_skips_step_when_false
    ran = false
    s1 = make_step(:s1) { ran = true }
    guard = -> (ctx) { false }

    f = Class.new do
      include Easyop::Flow
      flow guard, s1
    end

    f.call
    refute ran
  end

  def test_flow_lambda_guard_runs_step_when_true
    ran = false
    s1 = make_step(:s1) { ran = true }
    guard = -> (ctx) { true }

    f = Class.new do
      include Easyop::Flow
      flow guard, s1
    end

    f.call
    assert ran
  end

  def test_flow_guard_evaluated_with_current_ctx
    s1 = make_step(:s1) { ctx[:flag] = true }
    s2 = make_step(:s2) { ctx[:ran_s2] = true }
    guard = -> (ctx) { ctx[:flag] }

    f = Class.new do
      include Easyop::Flow
      flow s1, guard, s2
    end

    result = f.call
    assert result[:ran_s2]
  end

  # ── skip_if on step class ─────────────────────────────────────────────────────

  def test_flow_honours_step_skip_predicate
    skippable = make_step(:skippable) { ctx[:ran] = true }
    skippable.skip_if { |ctx| ctx[:skip] }

    f = Class.new do
      include Easyop::Flow
      flow skippable
    end

    result = f.call(skip: true)
    refute result[:ran]
  end

  # ── Empty flow ────────────────────────────────────────────────────────────────

  def test_empty_flow_returns_success
    f = make_flow
    assert_predicate f.call, :success?
  end

  # ── .prepare delegates to FlowBuilder ────────────────────────────────────────

  def test_dot_prepare_returns_flow_builder
    f = make_flow
    assert_instance_of Easyop::FlowBuilder, f.prepare
  end

end
