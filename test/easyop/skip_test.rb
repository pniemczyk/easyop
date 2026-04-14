# frozen_string_literal: true

require 'test_helper'

class SkipTest < Minitest::Test
  include EasyopTestHelper

  def make_op(&call_block)
    klass = Class.new do
      include Easyop::Operation
      define_method(:call, &call_block) if call_block
    end
    klass
  end

  # ── skip_if DSL ───────────────────────────────────────────────────────────────

  def test_dot_skip_predicate_returns_false_when_not_declared
    op = make_op
    ctx = Easyop::Ctx.new
    refute op.skip?(ctx)
  end

  def test_dot_skip_predicate_returns_true_when_condition_met
    op = make_op
    op.skip_if { |ctx| ctx[:skip] == true }
    ctx = Easyop::Ctx.new(skip: true)
    assert op.skip?(ctx)
  end

  def test_dot_skip_predicate_returns_false_when_condition_not_met
    op = make_op
    op.skip_if { |ctx| ctx[:skip] == true }
    ctx = Easyop::Ctx.new(skip: false)
    refute op.skip?(ctx)
  end

  def test_skip_predicate_stored_on_class
    op = make_op
    pred = -> (ctx) { ctx[:x] }
    op.skip_if(&pred)
    assert_equal pred, op._skip_predicate
  end

  # ── Integration with Flow (skip_if honoured during execution) ────────────────

  def test_skip_if_prevents_step_from_running_in_flow
    skipped = make_op { ctx[:ran] = true }
    skipped.skip_if { |ctx| ctx[:should_skip] }

    flow = Class.new do
      include Easyop::Flow
      flow skipped
    end

    result = flow.call(should_skip: true)
    assert_predicate result, :success?
    refute result[:ran]
  end

  def test_skip_if_false_means_step_runs_in_flow
    step = make_op { ctx[:ran] = true }
    step.skip_if { |ctx| false }

    flow = Class.new do
      include Easyop::Flow
      flow step
    end

    result = flow.call
    assert result[:ran]
  end
end
