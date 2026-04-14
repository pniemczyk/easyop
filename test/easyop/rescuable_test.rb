# frozen_string_literal: true

require 'test_helper'

class RescuableTest < Minitest::Test
  include EasyopTestHelper

  def make_op(&call_block)
    klass = Class.new do
      include Easyop::Operation
      define_method(:call, &call_block) if call_block
    end
    klass
  end

  # ── rescue_from with block ────────────────────────────────────────────────────

  def test_rescue_from_block_handles_matching_error
    op = make_op { raise ArgumentError, 'bad arg' }
    op.rescue_from(ArgumentError) { |e| ctx[:rescued] = e.message }

    result = op.call
    assert_equal 'bad arg', result[:rescued]
    assert_predicate result, :success?
  end

  def test_rescue_from_block_does_not_handle_unmatched_error
    op = make_op { raise TypeError, 'wrong type' }
    op.rescue_from(ArgumentError) { |e| ctx[:rescued] = e.message }

    assert_raises(TypeError) { op.call }
  end

  # ── rescue_from with :with symbol ─────────────────────────────────────────────

  def test_rescue_from_with_symbol_calls_method
    op = make_op { raise RuntimeError, 'boom' }
    op.define_method(:handle_error) { |e| ctx[:handled] = e.message }
    op.rescue_from(RuntimeError, with: :handle_error)

    result = op.call
    assert_equal 'boom', result[:handled]
  end

  # ── rescue_from with multiple classes ────────────────────────────────────────

  def test_rescue_from_handles_any_listed_class
    op = make_op { raise TypeError, 'type' }
    op.rescue_from(ArgumentError, TypeError) { |e| ctx[:rescued] = e.class.name }

    result = op.call
    assert_equal 'TypeError', result[:rescued]
  end

  # ── First match wins ──────────────────────────────────────────────────────────

  def test_rescue_from_first_match_wins
    op = make_op { raise ArgumentError, 'a' }
    op.rescue_from(ArgumentError) { |_e| ctx[:which] = :first }
    op.rescue_from(ArgumentError) { |_e| ctx[:which] = :second }

    result = op.call
    assert_equal :first, result[:which]
  end

  # ── Inheritance — child handlers win over parent ──────────────────────────────

  def test_rescue_from_child_handler_overrides_parent
    parent = make_op { raise RuntimeError, 'err' }
    parent.rescue_from(RuntimeError) { |_e| ctx[:who] = :parent }

    child = Class.new(parent)
    child.rescue_from(RuntimeError) { |_e| ctx[:who] = :child }

    result = child.call
    assert_equal :child, result[:who]
  end

  def test_rescue_from_parent_handler_used_when_no_child_handler
    parent = make_op { raise RuntimeError, 'err' }
    parent.rescue_from(RuntimeError) { |_e| ctx[:who] = :parent }

    child = Class.new(parent)
    result = child.call
    assert_equal :parent, result[:who]
  end

  # ── rescue handler can call ctx.fail! ─────────────────────────────────────────

  def test_rescue_from_handler_can_call_fail
    op = make_op { raise RuntimeError }
    op.rescue_from(RuntimeError) { |e| ctx.fail!(error: e.class.name) }

    result = op.call
    assert_predicate result, :failure?
    assert_equal 'RuntimeError', result.error
  end

  # ── Missing :with and no block raises ArgumentError ───────────────────────────

  def test_rescue_from_without_with_or_block_raises
    op = make_op
    assert_raises(ArgumentError) { op.rescue_from(RuntimeError) }
  end
end
