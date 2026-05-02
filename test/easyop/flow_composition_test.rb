# frozen_string_literal: true

require 'test_helper'
require 'easyop/scheduler'
require 'easyop/persistent_flow'
require_relative '../support/persistent_flow_stubs'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Fake AR record for testing subject attachment and serializer round-trips.
class FakeSubjectRecord < ActiveRecord::Base
  attr_reader :id

  @@registry = {}

  def self.name = 'FakeSubjectRecord'

  def self.find(id)
    @@registry[id] || raise("FakeSubjectRecord #{id} not found")
  end

  def initialize(id)
    @id = id
    @@registry[id] = self
  end
end

# ── Sync-only composition (no DB stubs needed) ────────────────────────────────

class FlowSyncCompositionTest < Minitest::Test
  include EasyopTestHelper

  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      define_method(:call, &blk) if blk
    end
  end

  def make_async_op(&blk)
    Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
      define_method(:call, &blk) if blk
    end
  end

  # ── Test 2: Mode 1 outer embeds Mode 1 sync inner ────────────────────────────

  def test_mode1_outer_embeds_sync_inner_flow
    ran = []
    op1    = make_op { ran << :op1 }
    step_a = make_op { ran << :step_a }
    step_b = make_op { ran << :step_b }
    op3    = make_op { ran << :op3 }
    set_const('CompSyncOp1',    op1)
    set_const('CompSyncStepA',  step_a)
    set_const('CompSyncStepB',  step_b)
    set_const('CompSyncOp3',    op3)

    inner = Class.new { include Easyop::Flow; flow step_a, step_b }
    outer = Class.new { include Easyop::Flow; flow op1, inner, op3 }
    set_const('CompSyncInner', inner)
    set_const('CompSyncOuter', outer)

    result = outer.call(x: 1)

    assert_instance_of Easyop::Ctx, result
    assert_equal [:op1, :step_a, :step_b, :op3], ran, 'inner steps run inline in order'
    assert_equal 1, result[:x]
  end

  # ── Test 3: Mode 1 outer embeds Mode 2 inner (fire-and-forget, no promotion) ──

  def test_mode1_outer_embeds_mode2_inner_does_not_promote
    ran      = []
    op1      = make_op { ran << :op1 }
    step_a   = make_op { ran << :step_a }
    async_b  = make_async_op { ran << :async_b_ran }
    op3      = make_op { ran << :op3 }
    set_const('CompFFOp1',    op1)
    set_const('CompFFStepA',  step_a)
    set_const('CompFFAsyncB', async_b)
    set_const('CompFFOp3',    op3)

    fire_forget_inner = Class.new { include Easyop::Flow; flow step_a, async_b.async(wait: 5) }
    outer             = Class.new { include Easyop::Flow; flow op1, fire_forget_inner, op3 }
    set_const('CompFFInner', fire_forget_inner)
    set_const('CompFFOuter', outer)

    captured = []
    Thread.current[:_easyop_async_capture]      = captured
    Thread.current[:_easyop_async_capture_only] = true

    result = outer.call(foo: :bar)

    assert_instance_of Easyop::Ctx, result,
                       'outer returns Ctx — Mode-2 inner does NOT promote outer to durable'
    assert_equal [:op1, :step_a, :op3], ran,
                 'sync steps run inline; async_b is enqueued not run'
    assert_equal 1, captured.size, 'exactly one async enqueue from the inner flow'
    assert_equal async_b, captured.first[:operation]
    assert_equal 5, captured.first[:wait]
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end

  # ── Test 7: Inner.async on a flow class raises AsyncFlowEmbeddingNotSupportedError ──

  def test_inner_async_raises_async_flow_embedding_error
    step = make_async_op
    set_const('CompAsyncFlowStep', step)

    inner = Class.new { include Easyop::Flow; plugin Easyop::Plugins::Async; flow step }
    outer = Class.new { include Easyop::Flow; flow inner.async(wait: 5) }
    set_const('CompAsyncFlowInner', inner)
    set_const('CompAsyncFlowOuter', outer)

    assert_raises Easyop::Flow::AsyncFlowEmbeddingNotSupportedError do
      outer.call
    end
  end

  # ── Test 8a: Inner.skip_if on a sync inner — skipped when guard truthy ───────

  def test_inner_skip_if_skips_sync_inner_when_truthy
    ran    = []
    step_a = make_async_op { ran << :step_a }
    op3    = make_op { ran << :op3 }
    set_const('CompSkipStepA', step_a)
    set_const('CompSkipOp3',   op3)

    inner = Class.new { include Easyop::Flow; plugin Easyop::Plugins::Async; flow step_a }
    outer = Class.new { include Easyop::Flow; flow inner.skip_if { true }, op3 }
    set_const('CompSkipInner', inner)
    set_const('CompSkipOuter', outer)

    result = outer.call

    assert_instance_of Easyop::Ctx, result
    assert_equal [:op3], ran, 'inner skipped; op3 still runs'
  end

  # ── Test 8b: Inner.skip_if on a sync inner — runs when guard falsy ───────────

  def test_inner_skip_if_runs_sync_inner_when_falsy
    ran    = []
    step_a = make_async_op { ran << :step_a }
    set_const('CompSkipRunStepA', step_a)

    inner = Class.new { include Easyop::Flow; plugin Easyop::Plugins::Async; flow step_a }
    outer = Class.new { include Easyop::Flow; flow inner.skip_if { false } }
    set_const('CompSkipRunInner', inner)
    set_const('CompSkipRunOuter', outer)

    outer.call
    assert_equal [:step_a], ran, 'inner ran because guard was falsy'
  end

  # ── Test 9: Inner.skip_if on a durable inner raises ConditionalDurableSubflowNotSupportedError ──

  def test_inner_skip_if_on_durable_inner_raises
    step = make_async_op
    set_const('CompCondDurableStep', step)

    durable_inner = Class.new do
      include Easyop::Flow
      plugin Easyop::Plugins::Async
      subject :user
      flow step
    end
    set_const('CompCondDurableInner', durable_inner)

    assert_raises Easyop::Flow::ConditionalDurableSubflowNotSupportedError do
      Class.new do
        include Easyop::Flow
        flow durable_inner.skip_if { true }
      end._resolved_flow_steps
    end
  end

  # ── Test 13: Three-level Mode-2 nesting — no subject anywhere, no FlowRun ────

  def test_three_level_mode2_nesting_never_promotes
    ran = []
    op_z      = make_op { ran << :z }
    async_deep = make_async_op { ran << :deep_ran }
    async_mid  = make_async_op { ran << :mid_ran }
    set_const('Comp3LvlZ',         op_z)
    set_const('Comp3LvlAsyncDeep', async_deep)
    set_const('Comp3LvlAsyncMid',  async_mid)

    deep = Class.new { include Easyop::Flow; flow op_z, async_deep.async(wait: 3) }
    mid  = Class.new { include Easyop::Flow; flow deep, async_mid.async(wait: 7) }
    outer = Class.new { include Easyop::Flow; flow mid }
    set_const('Comp3LvlDeep',  deep)
    set_const('Comp3LvlMid',   mid)
    set_const('Comp3LvlOuter', outer)

    captured = []
    Thread.current[:_easyop_async_capture]      = captured
    Thread.current[:_easyop_async_capture_only] = true

    result = outer.call(val: 1)

    assert_instance_of Easyop::Ctx, result,
                       'no subject anywhere — outer stays sync, returns Ctx'
    assert_equal [:z], ran,
                 'only the innermost sync op runs; both async steps are enqueued'
    assert_equal 2, captured.size, 'both async steps enqueued (async_deep and async_mid)'
    assert_includes captured.map { |c| c[:operation] }, async_deep
    assert_includes captured.map { |c| c[:operation] }, async_mid
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end
end

# ── Durable composition (requires FlowRun stubs) ─────────────────────────────

class FlowDurableCompositionTest < PersistentFlowTestBase
  # ── Test 4: Mode 1 outer with durable inner auto-promotes ────────────────────

  def test_mode1_outer_with_durable_inner_auto_promotes
    ran    = []
    op1    = make_op { ran << :op1 }
    step_a = make_op { ran << :step_a }
    op3    = make_op { ran << :op3 }
    set_const('CompPromoOp1',    op1)
    set_const('CompPromoStepA',  step_a)
    set_const('CompPromoOp3',    op3)

    user = FakeSubjectRecord.new(42)

    durable_inner = Class.new do
      include Easyop::Flow
      subject :user
      flow step_a
    end
    outer = Class.new { include Easyop::Flow; flow op1, durable_inner, op3 }
    set_const('CompPromoDurableInner', durable_inner)
    set_const('CompPromoOuter', outer)

    result = outer.call(user: user)

    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result,
                       'outer auto-promoted to durable via subject in inner'
    assert_equal 'CompPromoOuter', result.flow_class,
                 'FlowRun records the outer flow class, not the inner'
    assert_equal 'FakeSubjectRecord', result.subject_type
    assert_equal 42, result.subject_id
    assert_equal 'succeeded', result.status
    assert_equal [:op1, :step_a, :op3], ran,
                 'all steps — outer op1, flattened inner step_a, outer op3 — ran in order'
    assert_equal 1, flow_runs.size, 'exactly one FlowRun row for the outer'
  end

  # ── Test 10: Conflicting subjects — outer wins ────────────────────────────────

  def test_conflicting_subjects_outer_wins
    step   = make_op {}
    set_const('CompConflictStep', step)

    user  = FakeSubjectRecord.new(1)
    order = FakeSubjectRecord.new(2)

    inner = Class.new do
      include Easyop::Flow
      subject :order
      flow step
    end

    outer = Class.new do
      include Easyop::Flow
      subject :user
      flow inner
    end
    set_const('CompConflictInner', inner)
    set_const('CompConflictOuter', outer)

    result = outer.call(user: user, order: order)

    assert_equal 'FakeSubjectRecord', result.subject_type,
                 'subject_type is set from the user (outer subject)'
    assert_equal 1, result.subject_id,
                 'subject_id is from outer user (id=1), not inner order (id=2)'
  end

  # ── Test 11: No-subject outer + first-found inner subject ────────────────────

  def test_no_subject_outer_inherits_first_found_inner_subject
    step   = make_op {}
    set_const('CompFirstSubjectStep', step)

    user = FakeSubjectRecord.new(99)

    inner_with_subject = Class.new do
      include Easyop::Flow
      subject :user
      flow step
    end

    outer = Class.new { include Easyop::Flow; flow inner_with_subject }
    set_const('CompFirstSubjectInner', inner_with_subject)
    set_const('CompFirstSubjectOuter', outer)

    result = outer.call(user: user)

    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result
    assert_equal 'FakeSubjectRecord', result.subject_type
    assert_equal 99, result.subject_id
    assert_equal 'succeeded', result.status
  end

  # ── Test 12: Three-level nesting — subject bubbles to top ────────────────────

  def test_three_level_nesting_subject_bubbles_to_top
    ran = []
    op_a   = make_op { ran << :a }
    op_b   = make_op { ran << :b }
    op_c   = make_op { ran << :c }
    set_const('Comp3A', op_a)
    set_const('Comp3B', op_b)
    set_const('Comp3C', op_c)

    user = FakeSubjectRecord.new(7)

    deep_flow = Class.new do
      include Easyop::Flow
      subject :user
      flow op_c
    end

    mid_flow = Class.new { include Easyop::Flow; flow op_b, deep_flow }

    top_flow = Class.new { include Easyop::Flow; flow op_a, mid_flow }

    set_const('Comp3Deep', deep_flow)
    set_const('Comp3Mid',  mid_flow)
    set_const('Comp3Top',  top_flow)

    result = top_flow.call(user: user)

    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result,
                       'auto-promoted because deep_flow has a subject'
    assert_equal 'Comp3Top', result.flow_class
    assert_equal 'FakeSubjectRecord', result.subject_type
    assert_equal 7, result.subject_id
    assert_equal 'succeeded', result.status
    assert_equal [:a, :b, :c], ran,
                 'all three leaf steps ran in order via flattened resolved step list'
    assert_equal 3, flow_steps.size, 'one step record per leaf step'
  end

  # ── Test 5: Mode 3 outer with sync inner then durable inner ──────────────────

  def test_mode3_outer_embeds_sync_then_durable_inner
    ran = []
    op_x   = make_op { ran << :x }
    step_y = make_op { ran << :y }
    step_z = make_op { ran << :z }
    set_const('Comp5X', op_x)
    set_const('Comp5Y', step_y)
    set_const('Comp5Z', step_z)

    user = FakeSubjectRecord.new(5)

    sync_inner    = Class.new { include Easyop::Flow; flow step_y }
    durable_inner = Class.new { include Easyop::Flow; subject :user; flow step_z }

    outer = Class.new do
      include Easyop::Flow
      subject :user
      flow op_x, sync_inner, durable_inner
    end
    set_const('Comp5SyncInner',    sync_inner)
    set_const('Comp5DurableInner', durable_inner)
    set_const('Comp5Outer',        outer)

    result = outer.call(user: user)

    assert_equal 'succeeded', result.status
    assert_equal [:x, :y, :z], ran,
                 'op_x runs, then sync_inner runs as single step (step_y inside), then flattened step_z'
  end

  # ── Test 6: Mode 3 outer with Mode 2 inner — inner's async is fire-and-forget ──

  def test_mode3_outer_embeds_mode2_inner_fires_async_locally
    ran    = []
    op_outer = make_op { ran << :outer_op }
    step_a   = make_op { ran << :step_a }
    async_b  = make_async_op { ran << :async_b_ran }
    set_const('Comp6OuterOp', op_outer)
    set_const('Comp6StepA',   step_a)
    set_const('Comp6AsyncB',  async_b)

    user = FakeSubjectRecord.new(6)

    fire_forget_inner = Class.new { include Easyop::Flow; flow step_a, async_b.async(wait: 2) }
    outer = Class.new { include Easyop::Flow; subject :user; flow op_outer, fire_forget_inner }
    set_const('Comp6FFInner', fire_forget_inner)
    set_const('Comp6Outer',   outer)

    captured = []
    Thread.current[:_easyop_async_capture]      = captured
    Thread.current[:_easyop_async_capture_only] = true

    result = outer.call(user: user)

    # fire_forget_inner is Mode 2 — NOT flattened into the outer's durable step list.
    # It runs as a single durable step. Inside that step, step_a runs and async_b fires
    # via call_async (NOT via the DB scheduler).
    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result,
                       'outer is durable because it has subject :user'
    assert_equal 'succeeded', result.status
    assert_equal [:outer_op, :step_a], ran,
                 'outer_op and step_a ran inline; async_b was enqueued not run'
    assert_equal 1, captured.size,
                 'async_b fired via call_async (ActiveJob), not the durable scheduler'
    assert_equal async_b, captured.first[:operation]
    assert_equal 0, sched_tasks.size,
                 'no scheduled tasks — async_b used ActiveJob, not the DB scheduler'
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end
end
