# frozen_string_literal: true

require 'test_helper'

class PluginsTransactionalTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    ::ActiveRecord::Base.reset_test_state! if ::ActiveRecord::Base.respond_to?(:reset_test_state!)
  end

  def make_op(&call_block)
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Transactional
    end
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  # ── Wraps call in transaction ─────────────────────────────────────────────────

  def test_wraps_operation_in_transaction
    op = make_op { ctx[:ok] = true }
    op.call
    assert_equal 1, ::ActiveRecord::Base.tx_count
  end

  def test_transaction_contains_operation_result
    op = make_op { ctx[:val] = 42 }
    result = op.call
    assert_equal 42, result[:val]
  end

  # ── transactional false opt-out ───────────────────────────────────────────────

  def test_transactional_false_skips_transaction
    op = make_op { }
    op.transactional(false)
    op.call
    assert_equal 0, ::ActiveRecord::Base.tx_count
  end

  def test_transactional_inherited_true_by_default
    parent = make_op { }
    child  = Class.new(parent) { define_method(:call) { } }
    child.call
    assert_equal 1, ::ActiveRecord::Base.tx_count
  end

  def test_transactional_false_inherited_from_parent
    parent = make_op { }
    parent.transactional(false)
    child = Class.new(parent) { define_method(:call) { } }
    child.call
    assert_equal 0, ::ActiveRecord::Base.tx_count
  end

  # ── ctx.fail! inside transaction ─────────────────────────────────────────────

  def test_ctx_fail_inside_transaction_still_returns_failed_ctx
    op = make_op { ctx.fail!(error: 'bad') }
    result = op.call
    assert_predicate result, :failure?
    assert_equal 'bad', result.error
  end

  def test_ctx_failure_propagates_through_transaction_block
    rolled_back = false
    saved_ar = ::ActiveRecord.const_get(:Base)
    custom_ar = Module.new do
      define_singleton_method(:transaction) do |&blk|
        blk.call
      rescue Easyop::Ctx::Failure
        rolled_back = true
        raise
      end
      define_singleton_method(:reset_test_state!) { }
    end
    ::ActiveRecord.const_set(:Base, custom_ar)
    begin
      op = make_op { ctx.fail!(error: 'bad') }
      result = op.call
      assert_predicate result, :failure?
      assert rolled_back, 'Ctx::Failure must propagate through transaction block for rollback'
    ensure
      ::ActiveRecord.const_set(:Base, saved_ar)
    end
  end

  # ── Raises when no AR or Sequel ───────────────────────────────────────────────

  def test_raises_when_no_ar_or_sequel
    # This scenario only applies when neither AR nor Sequel is defined.
    # Since our test_helper always stubs AR::Base, skip this test.
    skip 'ActiveRecord::Base stub is always present in tests'
  end

  # ── plugin DSL installs via include ──────────────────────────────────────────

  def test_install_via_include_also_works
    klass = Class.new do
      include Easyop::Operation
      include Easyop::Plugins::Transactional
    end
    assert klass._transactional_enabled?
  end

  def test_plugin_dsl_registers_in_registered_plugins
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Transactional
    end
    plugins = op._registered_plugins.map { |p| p[:plugin] }
    assert_includes plugins, Easyop::Plugins::Transactional
  end

  # ── inheritance edge cases ────────────────────────────────────────────────────

  def test_subclass_can_disable_when_parent_enabled
    parent = make_op { }
    child  = Class.new(parent) do
      transactional false
      define_method(:call) { }
    end
    child.call
    assert_equal 0, ::ActiveRecord::Base.tx_count
  end

  def test_parent_unaffected_by_subclass_transactional_false
    parent = make_op { }
    child  = Class.new(parent) { transactional false }
    parent.call
    assert_equal 1, ::ActiveRecord::Base.tx_count
  end

  # ── before/after hooks run inside transaction ─────────────────────────────────

  def test_before_hook_runs_inside_transaction
    order  = []
    saved_ar = ::ActiveRecord.const_get(:Base)
    o = order
    custom_ar = Module.new do
      define_singleton_method(:transaction) do |&blk|
        o << :tx_open; blk.call; o << :tx_close
      end
      define_singleton_method(:reset_test_state!) { }
    end
    ::ActiveRecord.const_set(:Base, custom_ar)
    begin
      op = Class.new do
        include Easyop::Operation
        include Easyop::Plugins::Transactional
      end
      op.before { o << :before }
      op.after  { o << :after }
      op.define_method(:call) { o << :call }
      op.call
      assert_equal [:tx_open, :before, :call, :after, :tx_close], order
    ensure
      ::ActiveRecord.const_set(:Base, saved_ar)
    end
  end
end
