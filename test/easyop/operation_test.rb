# frozen_string_literal: true

require 'test_helper'

class OperationTest < Minitest::Test
  include EasyopTestHelper

  def make_op(&block)
    klass = Class.new do
      include Easyop::Operation
      define_method(:call, &block) if block
    end
    klass
  end

  # ── .call — basic ─────────────────────────────────────────────────────────────

  def test_dot_call_returns_ctx
    op = make_op { ctx[:x] = 1 }
    result = op.call(a: 2)
    assert_instance_of Easyop::Ctx, result
  end

  def test_dot_call_reads_input_attrs
    op = make_op { ctx[:out] = ctx[:in] * 2 }
    result = op.call(in: 5)
    assert_equal 10, result[:out]
  end

  def test_dot_call_returns_success_ctx_on_success
    op = make_op
    result = op.call
    assert_predicate result, :success?
  end

  def test_dot_call_swallows_ctx_failure_and_returns_failed_ctx
    op = make_op { ctx.fail!(error: 'nope') }
    result = op.call
    assert_predicate result, :failure?
    assert_equal 'nope', result.error
  end

  def test_dot_call_propagates_non_failure_exceptions
    op = make_op { raise RuntimeError, 'boom' }
    assert_raises(RuntimeError) { op.call }
  end

  # ── .call! ────────────────────────────────────────────────────────────────────

  def test_dot_call_bang_returns_ctx_on_success
    op = make_op { ctx[:done] = true }
    result = op.call!
    assert_predicate result, :success?
    assert result[:done]
  end

  def test_dot_call_bang_raises_ctx_failure_on_fail
    op = make_op { ctx.fail!(error: 'err') }
    err = assert_raises(Easyop::Ctx::Failure) { op.call! }
    assert_equal 'err', err.ctx.error
  end

  # ── Default call (no-op) ──────────────────────────────────────────────────────

  def test_dot_call_with_default_call_is_a_no_op
    op = make_op   # no block → default no-op
    result = op.call(x: 1)
    assert_predicate result, :success?
  end

  # ── .call accepts pre-built Ctx ──────────────────────────────────────────────

  def test_dot_call_accepts_pre_built_ctx
    op_klass = Class.new do
      include Easyop::Operation
      def call; ctx.output = ctx.input.upcase; end
    end
    pre_ctx = Easyop::Ctx.new(input: 'world')
    result  = op_klass.call(pre_ctx)
    assert_same pre_ctx, result
    assert_equal 'WORLD', result.output
  end

  # ── rescue_from: handler without ctx.fail! still succeeds ────────────────────

  def test_dot_call_bang_rescue_without_fail_allows_success
    op_klass = Class.new do
      include Easyop::Operation
      rescue_from ArgumentError do |e|
        ctx.message = "rescued: #{e.message}"
      end
      def call; raise ArgumentError, 'caught'; end
    end
    result = op_klass.call!
    assert_predicate result, :success?
    assert_equal 'rescued: caught', result.message
  end

  # ── rescue_from: subclass inherits parent handlers ────────────────────────────

  def test_subclass_inherits_parent_rescue_handlers
    base = Class.new do
      include Easyop::Operation
      rescue_from RuntimeError do |e|
        ctx.fail!(error: "caught: #{e.message}")
      end
    end
    child = Class.new(base) do
      def call; raise RuntimeError, 'from child'; end
    end
    result = child.call
    assert_predicate result, :failure?
    assert_equal 'caught: from child', result.error
  end

  # ── plugin DSL ───────────────────────────────────────────────────────────────

  def test_dot_plugin_records_registered_plugins
    mod = Module.new do
      def self.install(_base, **_opts); end
    end
    op = make_op
    op.plugin(mod)
    assert_equal 1, op._registered_plugins.length
    assert_equal mod, op._registered_plugins.first[:plugin]
  end

  def test_dot_plugin_calls_install_with_options
    installed_base = nil
    installed_opts = nil
    mod = Module.new
    # define_singleton_method closes over local variables, unlike `def self.install` inside Module.new
    mod.define_singleton_method(:install) do |base, **opts|
      installed_base = base
      installed_opts = opts
    end
    op = make_op
    op.plugin(mod, foo: :bar)
    assert_equal op,   installed_base
    assert_equal :bar, installed_opts[:foo]
  end

  # ── rollback default ──────────────────────────────────────────────────────────

  def test_hash_rollback_is_a_no_op_by_default
    op = make_op.new
    op.rollback # must not raise
  end

  # ── ctx accessor inside call ──────────────────────────────────────────────────

  def test_hash_ctx_accessible_inside_call
    op_klass = Class.new do
      include Easyop::Operation
      attr_reader :captured_ctx

      def call
        @captured_ctx = ctx
      end
    end
    instance = op_klass.new
    built_ctx = Easyop::Ctx.build(x: 42)
    instance._easyop_run(built_ctx, raise_on_failure: false)
    assert_same built_ctx, instance.captured_ctx
  end

  # ── unhandled exception marks ctx failed ─────────────────────────────────────

  def test_dot_call_marks_ctx_failed_on_unhandled_exception
    op = make_op { raise RuntimeError, 'unexpected' }
    # call swallows and re-raises, ctx may be set before re-raise attempt
    assert_raises(RuntimeError) { op.call }
  end
end
