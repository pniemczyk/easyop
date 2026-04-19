# frozen_string_literal: true

require "test_helper"

class Easyop::Testing::AssertionsTest < Minitest::Test
  include EasyopTestHelper
  include Easyop::Testing::Assertions

  # ── helpers ───────────────────────────────────────────────────────────────────

  def make_success_op(&block)
    klass = Class.new do
      include Easyop::Operation
      define_method(:call, &block) if block_given?
    end
    klass
  end

  def make_failure_op(error: "Something went wrong")
    err = error
    Class.new do
      include Easyop::Operation
      define_method(:call) { ctx.fail!(error: err) }
    end
  end

  # ── op_call ───────────────────────────────────────────────────────────────────

  def test_op_call_returns_ctx
    op  = make_success_op
    ctx = op_call(op)
    assert_instance_of Easyop::Ctx, ctx
  end

  def test_op_call_does_not_raise_on_failure
    op = make_failure_op
    assert_silent { op_call(op) }
  end

  def test_op_call_passes_attrs_to_operation
    op = make_success_op { ctx[:doubled] = ctx[:n] * 2 }
    ctx = op_call(op, n: 5)
    assert_equal 10, ctx[:doubled]
  end

  # ── op_call! ──────────────────────────────────────────────────────────────────

  def test_op_call_bang_raises_on_failure
    op = make_failure_op(error: "boom")
    assert_raises(Easyop::Ctx::Failure) { op_call!(op) }
  end

  def test_op_call_bang_returns_ctx_on_success
    op  = make_success_op
    ctx = op_call!(op)
    assert_instance_of Easyop::Ctx, ctx
  end

  # ── assert_op_success ─────────────────────────────────────────────────────────

  def test_assert_op_success_passes_on_successful_ctx
    op  = make_success_op
    ctx = op.call
    assert_silent { assert_op_success(ctx) }
  end

  def test_assert_op_success_fails_on_failure_ctx
    op  = make_failure_op(error: "broke")
    ctx = op.call
    ex  = assert_raises(Minitest::Assertion) { assert_op_success(ctx) }
    assert_includes ex.message, "broke"
  end

  def test_assert_op_success_includes_error_in_message
    op  = make_failure_op(error: "specific error message")
    ctx = op.call
    ex  = assert_raises(Minitest::Assertion) { assert_op_success(ctx) }
    assert_includes ex.message, "specific error message"
  end

  # ── assert_op_failure ─────────────────────────────────────────────────────────

  def test_assert_op_failure_passes_on_failed_ctx
    op  = make_failure_op
    ctx = op.call
    assert_silent { assert_op_failure(ctx) }
  end

  def test_assert_op_failure_fails_on_success_ctx
    op  = make_success_op
    ctx = op.call
    assert_raises(Minitest::Assertion) { assert_op_failure(ctx) }
  end

  def test_assert_op_failure_with_exact_error_string
    op  = make_failure_op(error: "Insufficient credits")
    ctx = op.call
    assert_silent { assert_op_failure(ctx, error: "Insufficient credits") }
  end

  def test_assert_op_failure_with_wrong_error_string_raises
    op  = make_failure_op(error: "Wrong error")
    ctx = op.call
    assert_raises(Minitest::Assertion) { assert_op_failure(ctx, error: "Different error") }
  end

  def test_assert_op_failure_with_matching_regex
    op  = make_failure_op(error: "Insufficient credits remaining")
    ctx = op.call
    assert_silent { assert_op_failure(ctx, error: /insufficient/i) }
  end

  def test_assert_op_failure_with_non_matching_regex
    op  = make_failure_op(error: "Something else")
    ctx = op.call
    assert_raises(Minitest::Assertion) { assert_op_failure(ctx, error: /insufficient/i) }
  end

  # ── assert_ctx_has ────────────────────────────────────────────────────────────

  def test_assert_ctx_has_passes_when_key_value_matches
    op  = make_success_op { ctx[:user_id] = 42; ctx[:plan] = "pro" }
    ctx = op.call
    assert_silent { assert_ctx_has(ctx, user_id: 42, plan: "pro") }
  end

  def test_assert_ctx_has_fails_when_value_does_not_match
    op  = make_success_op { ctx[:user_id] = 1 }
    ctx = op.call
    assert_raises(Minitest::Assertion) { assert_ctx_has(ctx, user_id: 999) }
  end

  def test_assert_ctx_has_fails_when_key_is_missing
    op  = make_success_op
    ctx = op.call
    assert_raises(Minitest::Assertion) { assert_ctx_has(ctx, missing_key: "value") }
  end

  # ── stub_op ───────────────────────────────────────────────────────────────────

  def test_stub_op_with_success_makes_call_return_successful_ctx
    op = make_success_op

    stub_op(op) do
      ctx = op.call(x: 1)
      assert_predicate ctx, :success?
    end
  end

  def test_stub_op_with_success_false_makes_call_return_failed_ctx
    op = make_success_op  # would succeed normally

    stub_op(op, success: false) do
      ctx = op.call
      assert_predicate ctx, :failure?
    end
  end

  def test_stub_op_with_custom_error_message
    op = make_success_op

    stub_op(op, success: false, error: "Custom error") do
      ctx = op.call
      assert_equal "Custom error", ctx.error
    end
  end

  def test_stub_op_call_bang_raises_on_failure
    op = make_success_op

    stub_op(op, success: false) do
      assert_raises(Easyop::Ctx::Failure) { op.call! }
    end
  end

  def test_stub_op_call_bang_returns_ctx_on_success
    op = make_success_op

    stub_op(op) do
      ctx = op.call!
      assert_predicate ctx, :success?
    end
  end

  def test_stub_op_yields_to_block_and_restores_normal_behavior
    op    = make_success_op { ctx[:ran] = true }
    value = nil

    stub_op(op, success: false) do
      value = "inside stub"
    end

    ctx = op.call
    # After the stub block ends, the real operation should run again
    assert_equal true, ctx[:ran]
    assert_equal "inside stub", value
  end
end
