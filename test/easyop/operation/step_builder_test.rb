# frozen_string_literal: true

require 'test_helper'
require 'easyop/operation/step_builder'
require 'easyop/plugins/async'

class StepBuilderTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    @op = make_op
    set_const('StepBuilderTestOp', @op)
    ActiveJob::Base.clear_jobs!
    Easyop::Plugins::Async.instance_variable_set(:@job_class, nil)
  end

  def make_op
    Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
    end
  end

  # ── Construction ─────────────────────────────────────────────────────────────

  def test_new_returns_frozen_opts
    builder = Easyop::Operation::StepBuilder.new(@op, async: true)
    assert_predicate builder.opts, :frozen?
  end

  def test_klass_reader
    builder = Easyop::Operation::StepBuilder.new(@op)
    assert_equal @op, builder.klass
  end

  # ── async entry point ─────────────────────────────────────────────────────────

  def test_async_sets_async_true
    builder = @op.async
    assert_equal true, builder.opts[:async]
  end

  def test_async_with_wait
    builder = @op.async(wait: 60)
    assert_equal true, builder.opts[:async]
    assert_equal 60,   builder.opts[:wait]
  end

  def test_async_with_queue
    builder = @op.async(queue: :low)
    assert_equal 'low', builder.opts[:queue].to_s
  end

  # ── wait entry point ──────────────────────────────────────────────────────────

  def test_wait_sets_wait_without_async
    builder = @op.wait(120)
    assert_equal 120,  builder.opts[:wait]
    refute             builder.opts[:async]
  end

  # ── skip_if / skip_unless entry points ───────────────────────────────────────

  def test_skip_if_stores_block
    blk     = -> (ctx) { ctx[:done] }
    builder = @op.skip_if(&blk)
    assert_equal blk, builder.opts[:skip_if]
  end

  def test_skip_unless_stores_block
    blk     = -> (ctx) { ctx[:enabled] }
    builder = @op.skip_unless(&blk)
    assert_equal blk, builder.opts[:skip_unless]
  end

  # ── on_exception ─────────────────────────────────────────────────────────────

  def test_on_exception_sets_policy
    builder = @op.on_exception(:cancel!)
    assert_equal :cancel!, builder.opts[:on_exception]
  end

  def test_on_exception_with_max_reattempts
    builder = @op.on_exception(:reattempt!, max_reattempts: 5)
    assert_equal :reattempt!, builder.opts[:on_exception]
    assert_equal 5,           builder.opts[:max_reattempts]
  end

  # ── tags ─────────────────────────────────────────────────────────────────────

  def test_tags_stores_list
    builder = @op.tags(:foo, :bar)
    assert_equal [:foo, :bar], builder.opts[:tags]
  end

  def test_tags_accumulate_across_calls
    builder = @op.async.tags(:a).tags(:b, :c)
    assert_equal [:a, :b, :c], builder.opts[:tags]
  end

  # ── Immutability ─────────────────────────────────────────────────────────────

  def test_chain_returns_new_instance
    b1 = @op.async
    b2 = b1.wait(60)
    refute_same b1, b2
  end

  def test_original_builder_unchanged_after_chain
    b1 = @op.async
    b1.wait(60)
    refute b1.opts.key?(:wait)
  end

  # ── Order independence ────────────────────────────────────────────────────────

  def test_skip_if_then_async_same_as_async_then_skip_if
    blk = -> (ctx) { ctx[:done] }
    a   = @op.skip_if(&blk).async(wait: 60)
    b   = @op.async(wait: 60).skip_if(&blk)
    assert_equal a.opts[:async],   b.opts[:async]
    assert_equal a.opts[:wait],    b.opts[:wait]
    assert_equal a.opts[:skip_if], b.opts[:skip_if]
  end

  # ── Last write wins (scalar opts) ────────────────────────────────────────────

  def test_last_wait_wins
    builder = @op.async(wait: 60).wait(120)
    assert_equal 120, builder.opts[:wait]
  end

  def test_last_skip_if_wins
    blk1 = -> (_) { true }
    blk2 = -> (_) { false }
    builder = @op.skip_if(&blk1).skip_if(&blk2)
    assert_equal blk2, builder.opts[:skip_if]
  end

  # ── to_step_config ───────────────────────────────────────────────────────────

  def test_to_step_config_returns_opts_hash
    builder = @op.async(wait: 60)
    assert_equal({ async: true, wait: 60 }, builder.to_step_config)
  end

  # ── call — delegates to call_async ───────────────────────────────────────────

  def test_call_enqueues_async_job
    @op.async.call(x: 1)
    assert_equal 1, ActiveJob::Base.jobs.size
  end

  def test_call_with_wait_passes_wait
    @op.async(wait: 120).call(x: 1)
    job = ActiveJob::Base.jobs.first
    assert_equal 120, job[:opts][:wait]
  end

  def test_call_equivalent_to_call_async
    spy = []
    Thread.current[:_easyop_async_capture]      = spy
    Thread.current[:_easyop_async_capture_only] = true

    @op.async(wait: 60).call(x: 2)

    assert_equal 1,  spy.size
    assert_equal 60, spy.first[:wait]
    assert_equal 2,  spy.first[:attrs][:x]
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end

  # ── PersistentFlowOnlyOptionsError ───────────────────────────────────────────

  def test_call_with_skip_if_raises_persistent_flow_only_error
    builder = @op.async.skip_if { true }
    assert_raises Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError do
      builder.call(x: 1)
    end
  end

  def test_call_with_on_exception_raises_persistent_flow_only_error
    builder = @op.on_exception(:cancel!)
    assert_raises Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError do
      builder.call
    end
  end

  def test_call_with_tags_raises_persistent_flow_only_error
    builder = @op.tags(:onboarding)
    assert_raises Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError do
      builder.call
    end
  end

  def test_call_with_blocking_raises_persistent_flow_only_error
    builder = @op.async(blocking: true)
    assert_raises Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError do
      builder.call(x: 1)
    end
  end

  def test_blocking_key_in_persistent_flow_only_keys
    assert_includes Easyop::Operation::StepBuilder::PERSISTENT_FLOW_ONLY_KEYS, :blocking
  end

  # ── Flow integration — sync steps with guards ────────────────────────────────

  def test_step_builder_in_flow_runs_step
    ran = []
    step = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
      define_method(:call) { ran << :ran }
    end
    set_const('FlowIntegrationOp', step)

    f = Class.new do
      include Easyop::Flow
      flow Class.new { include Easyop::Operation; def call; end },
           step.skip_if { |ctx| ctx[:skip] },
           Class.new { include Easyop::Operation; def call; end }
    end

    f.call(skip: false)
    assert_equal [:ran], ran
  end

  def test_step_builder_skip_if_skips_when_truthy
    ran = []
    step = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
      define_method(:call) { ran << :ran }
    end
    set_const('SkipIfFlowOp', step)

    f = Class.new do
      include Easyop::Flow
      flow step.skip_if { |_ctx| true }
    end

    f.call
    assert_empty ran
  end

  def test_step_builder_skip_unless_skips_when_falsy
    ran = []
    step = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
      define_method(:call) { ran << :ran }
    end
    set_const('SkipUnlessFlowOp', step)

    f = Class.new do
      include Easyop::Flow
      flow step.skip_unless { |_ctx| false }
    end

    f.call
    assert_empty ran
  end

  # AsyncStepRequiresPersistentFlowError is kept for rescue-compat but no longer raised.
  # Async steps in non-durable flows now fire-and-forget via call_async (Mode 2).
  def test_async_step_in_plain_flow_fires_and_forgets
    step = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
    end
    set_const('AsyncFlowFireForgetOp', step)

    f = Class.new do
      include Easyop::Flow
      flow step.async(wait: 60)
    end

    captured = []
    Thread.current[:_easyop_async_capture]      = captured
    Thread.current[:_easyop_async_capture_only] = true

    ctx = f.call(some: :attr)

    assert_instance_of Easyop::Ctx, ctx, 'non-durable flow must return Ctx'
    assert_equal 1, captured.size, 'async step must be enqueued exactly once'
    assert_equal step, captured.first[:operation]
    assert_equal 60, captured.first[:wait]
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end
end
