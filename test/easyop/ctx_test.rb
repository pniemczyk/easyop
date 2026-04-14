# frozen_string_literal: true

require 'test_helper'

class CtxTest < Minitest::Test
  include EasyopTestHelper

  # ── .build ──────────────────────────────────────────────────────────────────

  def test_dot_build_returns_ctx_unchanged_when_already_ctx
    ctx = Easyop::Ctx.new(x: 1)
    assert_same ctx, Easyop::Ctx.build(ctx)
  end

  def test_dot_build_wraps_hash_in_new_ctx
    ctx = Easyop::Ctx.build(a: 1)
    assert_instance_of Easyop::Ctx, ctx
    assert_equal 1, ctx[:a]
  end

  def test_dot_build_with_empty_hash
    ctx = Easyop::Ctx.build({})
    assert_instance_of Easyop::Ctx, ctx
    assert_predicate ctx, :success?
  end

  # ── Attribute access ([] / []=) ──────────────────────────────────────────────

  def test_hash_bracket_read_and_write
    ctx = Easyop::Ctx.new
    ctx[:name] = 'alice'
    assert_equal 'alice', ctx[:name]
  end

  def test_hash_bracket_coerces_key_to_symbol
    ctx = Easyop::Ctx.new
    ctx['foo'] = 42
    assert_equal 42, ctx[:foo]
    assert_equal 42, ctx['foo']
  end

  def test_hash_bracket_returns_nil_for_missing_key
    ctx = Easyop::Ctx.new
    assert_nil ctx[:missing]
  end

  # ── merge! ───────────────────────────────────────────────────────────────────

  def test_hash_merge_sets_multiple_attrs
    ctx = Easyop::Ctx.new
    result = ctx.merge!(a: 1, b: 2)
    assert_equal 1, ctx[:a]
    assert_equal 2, ctx[:b]
    assert_same ctx, result
  end

  # ── to_h ────────────────────────────────────────────────────────────────────

  def test_hash_to_h_returns_dup_of_attrs
    ctx = Easyop::Ctx.new(x: 10)
    h = ctx.to_h
    assert_equal({ x: 10 }, h)
    h[:x] = 99
    assert_equal 10, ctx[:x]
  end

  # ── key? ────────────────────────────────────────────────────────────────────

  def test_hash_key_predicate_true_when_set
    ctx = Easyop::Ctx.new(name: 'bob')
    assert ctx.key?(:name)
  end

  def test_hash_key_predicate_false_when_absent
    ctx = Easyop::Ctx.new
    refute ctx.key?(:name)
  end

  # ── slice ────────────────────────────────────────────────────────────────────

  def test_hash_slice_returns_subset
    ctx = Easyop::Ctx.new(a: 1, b: 2, c: 3)
    assert_equal({ a: 1, c: 3 }, ctx.slice(:a, :c))
  end

  def test_hash_slice_excludes_absent_keys
    ctx = Easyop::Ctx.new(a: 1)
    assert_equal({ a: 1 }, ctx.slice(:a, :z))
  end

  # ── success? / failure? ──────────────────────────────────────────────────────

  def test_hash_success_predicate_true_by_default
    ctx = Easyop::Ctx.new
    assert_predicate ctx, :success?
    assert_predicate ctx, :ok?
    refute_predicate ctx, :failure?
    refute_predicate ctx, :failed?
  end

  # ── fail! ────────────────────────────────────────────────────────────────────

  def test_hash_fail_raises_ctx_failure
    ctx = Easyop::Ctx.new
    assert_raises(Easyop::Ctx::Failure) { ctx.fail! }
  end

  def test_hash_fail_marks_ctx_as_failed
    ctx = Easyop::Ctx.new
    ctx.fail! rescue nil
    assert_predicate ctx, :failure?
    refute_predicate ctx, :success?
  end

  def test_hash_fail_with_attrs_sets_them_before_raising
    ctx = Easyop::Ctx.new
    ctx.fail!(error: 'boom') rescue nil
    assert_equal 'boom', ctx[:error]
    assert_predicate ctx, :failure?
  end

  def test_dot_failure_error_includes_message
    ctx = Easyop::Ctx.new
    err = assert_raises(Easyop::Ctx::Failure) { ctx.fail!(error: 'oops') }
    assert_includes err.message, 'oops'
    assert_same ctx, err.ctx
  end

  # ── error / errors conveniences ──────────────────────────────────────────────

  def test_hash_error_reads_error_key
    ctx = Easyop::Ctx.new(error: 'bad')
    assert_equal 'bad', ctx.error
  end

  def test_hash_error_writer
    ctx = Easyop::Ctx.new
    ctx.error = 'nope'
    assert_equal 'nope', ctx[:error]
  end

  def test_hash_errors_returns_empty_hash_by_default
    ctx = Easyop::Ctx.new
    assert_equal({}, ctx.errors)
  end

  def test_hash_errors_writer
    ctx = Easyop::Ctx.new
    ctx.errors = { name: 'is blank' }
    assert_equal({ name: 'is blank' }, ctx.errors)
  end

  # ── on_success / on_failure callbacks ────────────────────────────────────────

  def test_hash_on_success_yields_when_success
    ctx = Easyop::Ctx.new
    called = false
    result = ctx.on_success { |c| called = true; assert_same ctx, c }
    assert called
    assert_same ctx, result
  end

  def test_hash_on_success_does_not_yield_when_failure
    ctx = Easyop::Ctx.new
    ctx.fail! rescue nil
    called = false
    ctx.on_success { called = true }
    refute called
  end

  def test_hash_on_failure_yields_when_failure
    ctx = Easyop::Ctx.new
    ctx.fail! rescue nil
    called = false
    ctx.on_failure { |c| called = true }
    assert called
  end

  def test_hash_on_failure_does_not_yield_when_success
    ctx = Easyop::Ctx.new
    called = false
    ctx.on_failure { called = true }
    refute called
  end

  # ── Rollback support ──────────────────────────────────────────────────────────

  def test_hash_called_records_operation
    ctx = Easyop::Ctx.new
    op = Object.new
    ctx.called!(op)
    # rollback! calls #rollback on ops in reverse; verify at least it runs without error
    def op.rollback; end
    ctx.rollback!
  end

  def test_hash_rollback_calls_rollback_in_reverse_order
    ctx = Easyop::Ctx.new
    order = []
    op1 = Object.new; op1.define_singleton_method(:rollback) { order << :op1 }
    op2 = Object.new; op2.define_singleton_method(:rollback) { order << :op2 }
    ctx.called!(op1)
    ctx.called!(op2)
    ctx.rollback!
    assert_equal [:op2, :op1], order
  end

  def test_hash_rollback_runs_only_once
    ctx = Easyop::Ctx.new
    count = 0
    op = Object.new; op.define_singleton_method(:rollback) { count += 1 }
    ctx.called!(op)
    ctx.rollback!
    ctx.rollback!
    assert_equal 1, count
  end

  def test_hash_rollback_swallows_errors_in_individual_ops
    ctx = Easyop::Ctx.new
    op1 = Object.new; op1.define_singleton_method(:rollback) { raise 'explode' }
    op2 = Object.new; op2.define_singleton_method(:rollback) { }
    ctx.called!(op1)
    ctx.called!(op2)
    ctx.rollback! # must not raise
  end

  # ── deconstruct_keys (pattern matching) ──────────────────────────────────────

  def test_hash_deconstruct_keys_includes_success_and_failure_flags
    ctx = Easyop::Ctx.new(name: 'alice')
    h = ctx.deconstruct_keys(nil)
    assert_equal true,    h[:success]
    assert_equal false,   h[:failure]
    assert_equal 'alice', h[:name]
  end

  def test_hash_deconstruct_keys_with_key_list_slices
    ctx = Easyop::Ctx.new(a: 1, b: 2)
    h = ctx.deconstruct_keys([:a, :success])
    assert h.key?(:a)
    assert h.key?(:success)
    refute h.key?(:b)
  end

  # ── method_missing (dynamic attribute access) ─────────────────────────────────

  def test_hash_method_missing_reader_when_key_exists
    ctx = Easyop::Ctx.new(name: 'alice')
    assert_equal 'alice', ctx.name
  end

  def test_hash_method_missing_reader_raises_when_key_absent
    ctx = Easyop::Ctx.new
    assert_raises(NoMethodError) { ctx.missing_key }
  end

  def test_hash_method_missing_writer
    ctx = Easyop::Ctx.new
    ctx.name = 'bob'
    assert_equal 'bob', ctx[:name]
  end

  def test_hash_method_missing_predicate_returns_boolean
    ctx = Easyop::Ctx.new(active: true)
    assert_equal true, ctx.active?
  end

  def test_hash_method_missing_predicate_false_when_absent
    ctx = Easyop::Ctx.new
    assert_equal false, ctx.missing_attr?
  end

  # ── respond_to_missing? ───────────────────────────────────────────────────────

  def test_hash_respond_to_missing_true_for_writer
    ctx = Easyop::Ctx.new
    assert_respond_to ctx, :name=
  end

  def test_hash_respond_to_missing_true_for_predicate
    ctx = Easyop::Ctx.new
    assert_respond_to ctx, :active?
  end

  def test_hash_respond_to_missing_true_for_existing_key
    ctx = Easyop::Ctx.new(foo: 1)
    assert_respond_to ctx, :foo
  end

  def test_hash_respond_to_missing_false_for_absent_key
    ctx = Easyop::Ctx.new
    refute_respond_to ctx, :nonexistent
  end

  # ── inspect ──────────────────────────────────────────────────────────────────

  def test_hash_inspect_includes_status_ok
    ctx = Easyop::Ctx.new(x: 1)
    assert_includes ctx.inspect, 'ok'
    assert_includes ctx.inspect, 'Easyop::Ctx'
  end

  def test_hash_inspect_includes_status_failed_after_fail
    ctx = Easyop::Ctx.new
    ctx.fail! rescue nil
    assert_includes ctx.inspect, 'FAILED'
  end
end
