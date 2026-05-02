# frozen_string_literal: true

require 'test_helper'
require 'easyop/scheduler'
require 'easyop/persistent_flow'
require_relative '../support/persistent_flow_stubs'

# ── Configuration ─────────────────────────────────────────────────────────────

class PersistentFlowConfigurationTest < PersistentFlowTestBase
  def test_default_model_names
    Easyop.reset_config!
    assert_equal 'EasyFlowRun',     Easyop.config.persistent_flow_model
    assert_equal 'EasyFlowRunStep', Easyop.config.persistent_flow_step_model
  end

  def test_configurable_model_names
    Easyop.configure do |c|
      c.persistent_flow_model      = 'MyFlowRun'
      c.persistent_flow_step_model = 'MyFlowRunStep'
    end
    assert_equal 'MyFlowRun',     Easyop.config.persistent_flow_model
    assert_equal 'MyFlowRunStep', Easyop.config.persistent_flow_step_model
  end
end

# ── FlowRunModel mixin ────────────────────────────────────────────────────────

class FlowRunModelTest < PersistentFlowTestBase
  def setup
    super
    @run = PersistentFlowTestStubs::FakeFlowRun.new
    @run.id = 1
  end

  def test_pending_predicate
    @run.status = 'pending'
    assert_predicate @run, :pending?
    refute_predicate @run, :running?
    refute_predicate @run, :terminal?
  end

  def test_running_predicate
    @run.status = 'running'
    assert_predicate @run, :running?
    refute_predicate @run, :terminal?
  end

  def test_succeeded_is_terminal
    @run.status = 'succeeded'
    assert_predicate @run, :succeeded?
    assert_predicate @run, :terminal?
  end

  def test_failed_is_terminal
    @run.status = 'failed'
    assert_predicate @run, :failed?
    assert_predicate @run, :terminal?
  end

  def test_cancelled_is_terminal
    @run.status = 'cancelled'
    assert_predicate @run, :cancelled?
    assert_predicate @run, :terminal?
  end

  def test_cancel_transitions_to_cancelled
    @run.status = 'running'
    @run.cancel!
    assert_equal 'cancelled', @run.status
    refute_nil @run.finished_at
  end

  def test_cancel_is_idempotent_on_terminal
    @run.status = 'succeeded'
    @run.cancel!
    assert_equal 'succeeded', @run.status
  end

  def test_pause_transitions_to_paused
    @run.status = 'running'
    @run.pause!
    assert_equal 'paused', @run.status
  end

  def test_pause_ignored_when_not_running
    @run.status = 'succeeded'
    @run.pause!
    assert_equal 'succeeded', @run.status
  end
end

# ── FlowRunStepModel mixin ────────────────────────────────────────────────────

class FlowRunStepModelTest < PersistentFlowTestBase
  def test_status_predicates
    step = PersistentFlowTestStubs::FakeFlowRunStep.new
    step.status = 'completed'
    assert_predicate step, :completed?
    refute_predicate step, :failed?
    refute_predicate step, :skipped?
  end
end

# ── Runner — sync-only flows ──────────────────────────────────────────────────

class RunnerSyncFlowTest < PersistentFlowTestBase
  def test_all_sync_steps_run_and_flow_succeeds
    ran = []
    step_a = make_op { ran << :a }
    step_b = make_op { ran << :b }
    set_const('SyncFlowA', step_a)
    set_const('SyncFlowB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b
    end
    set_const('SyncFlow', flow)

    run = flow.start!
    assert_equal 'succeeded', run.status
    assert_equal [:a, :b], ran
    assert_equal 2, flow_steps.size
    assert flow_steps.all? { |s| s.status == 'completed' }
  end

  def test_step_receives_ctx_values
    received = []
    step = make_op { received << ctx[:name] }
    set_const('CtxFlowStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('CtxFlow', flow)

    flow.start!(name: 'Alice')
    assert_equal ['Alice'], received
  end

  def test_step_can_write_ctx_for_next_step
    step_a   = make_op { ctx[:x] = 42 }
    received = []
    step_b   = make_op { received << ctx[:x] }
    set_const('CtxWriteA', step_a)
    set_const('CtxWriteB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b
    end
    set_const('CtxWriteFlow', flow)

    flow.start!
    assert_equal [42], received
  end

  def test_flow_fails_when_step_calls_ctx_fail
    step = make_op { ctx.fail!(error: 'oops') }
    set_const('FailStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('FailFlow', flow)

    run = flow.start!
    assert_equal 'failed', run.status
    assert flow_steps.any? { |s| s.status == 'failed' }
  end

  def test_skip_if_skips_step_when_truthy
    ran    = []
    step_a = make_op { ran << :a }
    step_b = make_async_op { ran << :b }
    set_const('SkipIfA', step_a)
    set_const('SkipIfB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.skip_if { |ctx| ctx[:skip_b] }
    end
    set_const('SkipIfFlow', flow)

    run = flow.start!(skip_b: true)
    assert_equal 'succeeded', run.status
    assert_equal [:a], ran
    assert flow_steps.any? { |s| s.status == 'skipped' }
  end

  def test_skip_unless_skips_step_when_falsy
    ran  = []
    step = make_async_op { ran << :ran }
    set_const('SkipUnlessStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step.skip_unless { |ctx| ctx[:enabled] }
    end
    set_const('SkipUnlessFlow', flow)

    run = flow.start!(enabled: false)
    assert_equal 'succeeded', run.status
    assert_empty ran
  end

  def test_lambda_guard_skips_step_when_falsy
    ran    = []
    step_a = make_op { ran << :a }
    step_b = make_op { ran << :b }
    set_const('LambdaGuardA', step_a)
    set_const('LambdaGuardB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a,
           ->(ctx) { ctx[:run_b] },
           step_b
    end
    set_const('LambdaGuardFlow', flow)

    run = flow.start!(run_b: false)
    assert_equal 'succeeded', run.status
    assert_equal [:a], ran
  end

  def test_lambda_guard_runs_step_when_truthy
    ran    = []
    step_a = make_op { ran << :a }
    step_b = make_op { ran << :b }
    set_const('LambdaRunA', step_a)
    set_const('LambdaRunB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a,
           ->(ctx) { ctx[:run_b] },
           step_b
    end
    set_const('LambdaRunFlow', flow)

    run = flow.start!(run_b: true)
    assert_equal 'succeeded', run.status
    assert_equal [:a, :b], ran
  end
end

# ── Runner — async steps ──────────────────────────────────────────────────────

class RunnerAsyncFlowTest < PersistentFlowTestBase
  def test_async_step_schedules_a_task_and_pauses
    ran    = []
    step_a = make_op       { ran << :a }
    step_b = make_async_op { ran << :b }
    set_const('AsyncFlowA', step_a)
    set_const('AsyncFlowB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async
    end
    set_const('AsyncFlow', flow)

    run = flow.start!
    assert_equal [:a], ran
    assert_equal 'running', run.status
    assert_equal 1, sched_tasks.size
    assert_equal 'Easyop::PersistentFlow::PerformStepOperation',
                 sched_tasks.first.operation_class
  end

  def test_scheduler_tick_runs_async_step_and_completes_flow
    ran    = []
    step_a = make_op       { ran << :a }
    step_b = make_async_op { ran << :b }
    set_const('PerfJobA', step_a)
    set_const('PerfJobB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async
    end
    set_const('PerfJobFlow', flow)

    run = flow.start!
    Easyop::Scheduler.tick_now!

    assert_equal [:a, :b], ran
    assert_equal 'succeeded', run.status
  end

  def test_async_step_with_wait_sets_run_at_in_future
    step = make_async_op {}
    set_const('WaitStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step.async(wait: 300)
    end
    set_const('WaitFlow', flow)

    before = Time.current
    flow.start!
    task = sched_tasks.first

    assert task.run_at >= before + 299
  end

  def test_mixed_sync_async_sync_flow
    ran    = []
    step_a = make_op       { ran << :a }
    step_b = make_async_op { ran << :b }
    step_c = make_op       { ran << :c }
    set_const('MixedA', step_a)
    set_const('MixedB', step_b)
    set_const('MixedC', step_c)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async, step_c
    end
    set_const('MixedFlow', flow)

    run = flow.start!
    assert_equal [:a], ran

    Easyop::Scheduler.tick_now!

    assert_equal [:a, :b, :c], ran
    assert_equal 'succeeded', run.status
  end

  def test_multiple_async_steps_require_multiple_ticks
    ran    = []
    step_a = make_async_op { ran << :a }
    step_b = make_async_op { ran << :b }
    set_const('MultiAsyncA', step_a)
    set_const('MultiAsyncB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a.async, step_b.async
    end
    set_const('MultiAsyncFlow', flow)

    run = flow.start!
    assert_equal [], ran

    Easyop::Scheduler.tick_now!
    assert_equal [:a], ran

    Easyop::Scheduler.tick_now!
    assert_equal [:a, :b], ran
    assert_equal 'succeeded', run.status
  end

  def test_ctx_persists_across_async_boundary
    received = []
    step_a   = make_op       { ctx[:value] = 99 }
    step_b   = make_async_op { ctx[:value] = ctx[:value] * 2 }
    step_c   = make_op       { received << ctx[:value] }
    set_const('CtxPersistA', step_a)
    set_const('CtxPersistB', step_b)
    set_const('CtxPersistC', step_c)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async, step_c
    end
    set_const('CtxPersistFlow', flow)

    flow.start!
    Easyop::Scheduler.tick_now!

    assert_equal [198], received
  end
end

# ── Runner — cancellation and pause ──────────────────────────────────────────

class RunnerCancellationTest < PersistentFlowTestBase
  def test_cancel_prevents_async_continuation
    ran    = []
    step_a = make_op       { ran << :a }
    step_b = make_async_op { ran << :b }
    set_const('CancelA', step_a)
    set_const('CancelB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async
    end
    set_const('CancelFlow', flow)

    run = flow.start!
    run.cancel!
    assert_equal 'cancelled', run.status

    Easyop::Scheduler.tick_now!
    assert_equal [:a], ran
  end

  def test_advance_is_no_op_on_cancelled_flow
    run = PersistentFlowTestStubs::FakeFlowRun.create!(
      flow_class:         'DoesNotExist',
      context_data:       '{}',
      status:             'cancelled',
      current_step_index: 0
    )

    Easyop::PersistentFlow::Runner.advance!(run)
    assert_equal 'cancelled', run.status
  end

  def test_pause_transitions_to_paused
    step_a = make_op       {}
    step_b = make_async_op {}
    set_const('PauseA', step_a)
    set_const('PauseB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async
    end
    set_const('PauseFlow', flow)

    run = flow.start!
    run.pause!
    assert_equal 'paused', run.status
  end

  def test_resume_re_advances_paused_flow
    ran    = []
    step_a = make_op       { ran << :a }
    step_b = make_async_op { ran << :b }
    set_const('ResumeA', step_a)
    set_const('ResumeB', step_b)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_a, step_b.async
    end
    set_const('ResumeFlow', flow)

    run = flow.start!
    run.pause!
    assert_equal 'paused', run.status

    run.resume!
    # After resume, flow schedules the async step again
    assert_equal 'running', run.status
  end
end

# ── Runner — on_exception policies ────────────────────────────────────────────

class RunnerExceptionPolicyTest < PersistentFlowTestBase
  def test_exception_fails_flow_by_default
    step = make_op { raise 'boom' }
    set_const('ExceptStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('ExceptFlow', flow)

    run = flow.start!
    assert_equal 'failed', run.status
    assert flow_steps.any? { |s| s.status == 'failed' && s.error_class == 'RuntimeError' }
  end

  def test_on_exception_cancel_fails_flow
    step_class = make_async_op { raise 'explicit cancel' }
    set_const('CancelExceptStep', step_class)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_class.on_exception(:cancel!)
    end
    set_const('CancelExceptFlow', flow)

    run = flow.start!
    assert_equal 'failed', run.status
  end

  def test_on_exception_reattempt_schedules_retry
    step_class = make_async_op { raise 'transient' }
    set_const('RetryStep', step_class)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_class.on_exception(:reattempt!, max_reattempts: 3)
    end
    set_const('RetryFlow', flow)

    run = flow.start!
    assert_equal 'running', run.status
    # A retry task should have been scheduled
    retry_tasks = sched_tasks.select { |t| t.tags&.include?("flow_run:#{run.id}") }
    assert retry_tasks.any?
  end

  def test_on_exception_reattempt_fails_after_max_attempts
    attempt_count = 0
    step_class = make_async_op { attempt_count += 1; raise 'always fails' }
    set_const('MaxRetryStep', step_class)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step_class.on_exception(:reattempt!, max_reattempts: 2)
    end
    set_const('MaxRetryFlow', flow)

    run = flow.start!      # attempt 1 — fails, schedules retry
    assert_equal 1, attempt_count

    Easyop::Scheduler.tick_now!   # attempt 2 — fails, schedules retry
    assert_equal 2, attempt_count

    Easyop::Scheduler.tick_now!   # attempt 3 — fails, max reached
    assert_equal 3, attempt_count
    assert_equal 'failed', run.status
  end
end

# ── PersistentFlow.start! — subject declaration ───────────────────────────────

class PersistentFlowSubjectTest < PersistentFlowTestBase
  def test_subject_macro_stores_association_name
    flow = Class.new do
      include Easyop::PersistentFlow
      subject :user
    end
    set_const('SubjectFlow', flow)

    assert_equal :user, flow._persistent_flow_subject
  end

  def test_start_without_subject_creates_run_with_nil_subject
    step = make_op {}
    set_const('NoSubjectStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('NoSubjectFlow', flow)

    run = flow.start!(x: 1)
    assert_equal 'NoSubjectFlow', run.flow_class
    assert_nil run.subject_type
  end
end

# ── start! — creates a FlowRun row ────────────────────────────────────────────

class PersistentFlowStartTest < PersistentFlowTestBase
  def test_start_creates_flow_run_record
    step = make_op {}
    set_const('StartTestStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('StartTestFlow', flow)

    assert_equal 0, flow_runs.size
    flow.start!
    assert_equal 1, flow_runs.size
  end

  def test_start_returns_flow_run_instance
    step = make_op {}
    set_const('ReturnRunStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('ReturnRunFlow', flow)

    run = flow.start!
    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, run
  end

  def test_start_with_empty_flow_succeeds_immediately
    flow = Class.new { include Easyop::PersistentFlow }
    set_const('EmptyPersistentFlow', flow)

    run = flow.start!
    assert_equal 'succeeded', run.status
  end

  def test_start_records_flow_class_name
    step = make_op {}
    set_const('ClassNameStep', step)

    flow = Class.new do
      include Easyop::PersistentFlow
      flow step
    end
    set_const('ClassNameFlow', flow)

    run = flow.start!
    assert_equal 'ClassNameFlow', run.flow_class
  end
end

# ── Three-mode dispatch: Easyop::Flow + subject ───────────────────────────────
#
# Mode 1: no subject, no async  → Ctx
# Mode 2: no subject, has async → Ctx + fire-and-forget via call_async
# Mode 3: subject declared      → FlowRun (durable, suspend & resume)

class FlowDurableDispatchTest < PersistentFlowTestBase
  def test_mode1_call_returns_ctx
    ran  = []
    step = make_op { ran << :a }
    set_const('Mode1StepA', step)

    flow = Class.new do
      include Easyop::Flow
      flow step
    end
    set_const('Mode1Flow', flow)

    result = flow.call(x: 1)

    assert_instance_of Easyop::Ctx, result, 'Mode 1 must return Ctx'
    assert_equal [:a], ran
    assert_empty flow_runs, 'Mode 1 must NOT write a FlowRun row'
  end

  def test_mode2_call_returns_ctx_and_fires_call_async
    ran          = []
    sync_step    = make_op { ran << :sync }
    async_step   = make_async_op { ran << :async_inline }
    skipped_step = make_async_op { ran << :skipped }
    after_step   = make_op { ran << :after }
    set_const('Mode2SyncStep',    sync_step)
    set_const('Mode2AsyncStep',   async_step)
    set_const('Mode2SkippedStep', skipped_step)
    set_const('Mode2AfterStep',   after_step)

    flow = Class.new do
      include Easyop::Flow
      flow sync_step,
           async_step.async(wait: 30),
           skipped_step.async(wait: 5).skip_if { |_ctx| true },
           after_step
    end
    set_const('Mode2Flow', flow)

    captured = []
    Thread.current[:_easyop_async_capture]      = captured
    Thread.current[:_easyop_async_capture_only] = true

    result = flow.call(val: 99)

    assert_instance_of Easyop::Ctx, result, 'Mode 2 must return Ctx'
    assert_equal [:sync, :after], ran,
                 'sync_step and after_step run inline; async_step is enqueued not run'
    assert_empty flow_runs, 'Mode 2 must NOT write a FlowRun row'
    assert_equal 1, captured.size, 'exactly one async step enqueued'
    assert_equal async_step,  captured.first[:operation]
    assert_equal 30,          captured.first[:wait]
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end

  def test_mode2_start_bang_alias_also_returns_ctx
    step = make_async_op {}
    set_const('Mode2StartBangStep', step)

    flow = Class.new do
      include Easyop::Flow
      flow step.async
    end
    set_const('Mode2StartBangFlow', flow)

    captured = []
    Thread.current[:_easyop_async_capture]      = captured
    Thread.current[:_easyop_async_capture_only] = true

    result = flow.start!

    assert_instance_of Easyop::Ctx, result
    assert_equal 1, captured.size
  ensure
    Thread.current[:_easyop_async_capture]      = nil
    Thread.current[:_easyop_async_capture_only] = nil
  end

  def test_mode3_call_with_subject_returns_flow_run
    ran  = []
    step = make_op { ran << :a }
    set_const('Mode3SubjectStep', step)

    flow = Class.new do
      include Easyop::Flow
      subject :order
      flow step
    end
    set_const('Mode3SubjectFlow', flow)

    result = flow.call(order: nil, extra: :val)

    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result
    assert_equal 'succeeded', result.status
    assert_equal 'Mode3SubjectFlow', result.flow_class
    assert_equal [:a], ran
    assert_equal 1, flow_runs.size
  end

  def test_mode3_subject_async_suspends_at_async_step
    ran       = []
    sync_step = make_op { ran << :sync }
    async_op  = make_async_op { ran << :async_ran }
    set_const('Mode3SuspendSync',  sync_step)
    set_const('Mode3SuspendAsync', async_op)

    flow = Class.new do
      include Easyop::Flow
      subject :order
      flow sync_step, async_op.async(wait: 0)
    end
    set_const('Mode3SuspendFlow', flow)

    result = flow.call(order: nil)

    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result
    assert_equal 'running', result.status
    assert_equal [:sync], ran,
                 'sync step ran; async step did NOT run yet (flow suspended)'
    assert_equal 1, sched_tasks.size, 'async step scheduled via DB scheduler'
    assert_equal 'Easyop::PersistentFlow::PerformStepOperation',
                 sched_tasks.first.operation_class
  end

  def test_mode3_start_bang_alias_returns_flow_run
    step = make_op {}
    set_const('Mode3StartBangStep', step)

    flow = Class.new do
      include Easyop::Flow
      subject :order
      flow step
    end
    set_const('Mode3StartBangFlow', flow)

    result = flow.start!(order: nil)

    assert_instance_of PersistentFlowTestStubs::FakeFlowRun, result
    assert_equal 'succeeded', result.status
  end

  def test_mode3_durable_support_not_loaded_raises_clear_error
    step = make_op {}
    set_const('Mode3NoRunnerStep', step)

    flow = Class.new do
      include Easyop::Flow
      subject :order
      flow step
    end
    set_const('Mode3NoRunnerFlow', flow)

    # Temporarily hide the Runner to simulate it not being loaded
    runner = Easyop::PersistentFlow.send(:remove_const, :Runner)

    err = assert_raises(Easyop::Flow::DurableSupportNotLoadedError) { flow.call(order: nil) }
    assert_match 'easyop/persistent_flow', err.message
  ensure
    Easyop::PersistentFlow.const_set(:Runner, runner) if runner
  end

  def test_mode2_persistent_flow_only_options_raise
    step = make_async_op {}
    set_const('Mode2BadOptsStep', step)

    flow = Class.new do
      include Easyop::Flow
      flow step.async.on_exception(:cancel!)   # on_exception is durable-only
    end
    set_const('Mode2BadOptsFlow', flow)

    assert_raises Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError do
      flow.call
    end
  end
end
