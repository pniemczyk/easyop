# frozen_string_literal: true

require 'test_helper'

class HooksTest < Minitest::Test
  include EasyopTestHelper

  def make_op
    Class.new do
      include Easyop::Operation
      attr_reader :log

      def initialize
        @log = []
      end

      def call
        @log << :call
      end
    end
  end

  # ── before hooks ─────────────────────────────────────────────────────────────

  def test_before_symbol_hook_runs_before_call
    klass = make_op
    klass.before(:prep)
    klass.define_method(:prep) { @log << :prep }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:prep, :call], result.log
  end

  def test_before_block_hook_runs_before_call
    klass = make_op
    klass.before { @log << :blk }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:blk, :call], result.log
  end

  def test_multiple_before_hooks_run_in_order
    klass = make_op
    klass.before { @log << :b1 }
    klass.before { @log << :b2 }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:b1, :b2, :call], result.log
  end

  # ── after hooks ──────────────────────────────────────────────────────────────

  def test_after_symbol_hook_runs_after_call
    klass = make_op
    klass.after(:cleanup)
    klass.define_method(:cleanup) { @log << :cleanup }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:call, :cleanup], result.log
  end

  def test_after_block_hook_runs_after_call
    klass = make_op
    klass.after { @log << :after }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:call, :after], result.log
  end

  def test_after_hook_runs_even_when_ctx_fail_called
    klass = make_op
    klass.define_method(:call) { @log << :call; ctx.fail! }
    klass.after { @log << :after }

    inst = klass.new
    inst._easyop_run(Easyop::Ctx.new, raise_on_failure: false)
    assert_equal [:call, :after], inst.log
  end

  # ── around hooks ─────────────────────────────────────────────────────────────

  def test_around_symbol_hook_wraps_call
    klass = make_op
    klass.around(:timed)
    # Use class_eval + def so `yield` works inside a method body (not a proc).
    klass.class_eval do
      def timed
        @log << :start
        yield
        @log << :end
      end
    end

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:start, :call, :end], result.log
  end

  def test_around_block_hook_wraps_call
    klass = make_op
    klass.around { |inner| @log << :wrap_start; inner.call; @log << :wrap_end }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:wrap_start, :call, :wrap_end], result.log
  end

  def test_multiple_around_hooks_nest_in_order
    klass = make_op
    klass.around { |i| @log << :a1_start; i.call; @log << :a1_end }
    klass.around { |i| @log << :a2_start; i.call; @log << :a2_end }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:a1_start, :a2_start, :call, :a2_end, :a1_end], result.log
  end

  def test_around_before_after_ordering
    klass = make_op
    klass.around { |i| @log << :around_start; i.call; @log << :around_end }
    klass.before { @log << :before }
    klass.after  { @log << :after }

    result = klass.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_equal [:around_start, :before, :call, :after, :around_end], result.log
  end

  # ── Hook inheritance ──────────────────────────────────────────────────────────

  def test_subclass_inherits_parent_hooks
    parent = make_op
    parent.before { @log << :parent_before }

    child = Class.new(parent)
    child.before { @log << :child_before }

    result = child.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    assert_includes result.log, :parent_before
    assert_includes result.log, :child_before
  end

  def test_child_hooks_do_not_affect_parent
    parent = make_op
    child = Class.new(parent)
    child.before { @log << :child_only }

    parent_inst = parent.new.tap { |i| i._easyop_run(Easyop::Ctx.new, raise_on_failure: false) }
    refute_includes parent_inst.log, :child_only
  end
end
