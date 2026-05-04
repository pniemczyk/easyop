# EasyOp — Durable Flows Reference

> v0.5+. Requires `require "easyop/scheduler"` and `require "easyop/persistent_flow"`.

## What makes a flow durable?

`subject` is the **only** durability trigger. An `.async` step alone (without `subject`)
is Mode 2 (fire-and-forget) — it enqueues via ActiveJob and the flow continues immediately.
Only `subject` makes a flow Mode 3 (suspend-and-resume with a DB-backed `FlowRun`).

```ruby
# Mode 2 — fire-and-forget, returns Ctx
class RegisterAndNotify
  include Easyop::Flow
  flow CreateUser, SendWelcomeEmail.async   # no subject → Mode 2
end

# Mode 3 — durable, returns FlowRun
class OnboardSubscriber
  include Easyop::Flow
  subject :user                            # ← triggers Mode 3
  flow CreateAccount, SendWelcomeEmail.async, SendNudge.async(wait: 3.days)
end
```

## Setup ceremony

### 1. Gemfile / initializer requirements

```ruby
# Load order matters: scheduler before persistent_flow
require 'easyop/scheduler'
require 'easyop/persistent_flow'
```

`require "easyop"` alone does NOT auto-require either of these. Omitting
`require "easyop/persistent_flow"` when `subject` is declared raises
`Easyop::Flow::DurableSupportNotLoadedError` at call time.

### 2. Generate AR models and migrations

```bash
bin/rails generate easyop:install
```

This creates:

- `db/migrate/TIMESTAMP_create_easy_flow_runs.rb`
- `db/migrate/TIMESTAMP_create_easy_flow_run_steps.rb`
- `app/models/easy_flow_run.rb` — includes `Easyop::PersistentFlow::FlowRunModel`
- `app/models/easy_flow_run_step.rb` — includes `Easyop::PersistentFlow::FlowRunStepModel`

Run `bin/rails db:migrate` after generating.

### 3. Configure model names (optional)

Default model names are `'EasyFlowRun'` and `'EasyFlowRunStep'`. Override in the initializer:

```ruby
Easyop.configure do |c|
  c.persistent_flow_model      = 'MyFlowRun'
  c.persistent_flow_step_model = 'MyFlowRunStep'
end
```

## Declaring a durable flow

```ruby
require 'easyop/scheduler'
require 'easyop/persistent_flow'

class OnboardSubscriber
  include Easyop::Flow

  # subject binds a polymorphic AR reference to the FlowRun.
  # The key must match an AR record passed in attrs.
  subject :user

  flow CreateAccount,                                    # sync — runs inline
       SendWelcomeEmail.async,                           # async — deferred via Scheduler
       SendNudge.async(wait: 3.days)                    # async with delay
                .skip_if { |ctx| ctx[:skip_nudge] },   # guard evaluated at runtime
       RecordComplete                                    # sync
end
```

**Note:** `.async`, `.skip_if`, `.on_exception`, and `.tags` are step-builder methods.
They require `plugin Easyop::Plugins::Async` on the operation class (or a parent it
inherits from). An operation used as a bare step without modifiers does not need the plugin.

## Calling a durable flow

```ruby
flow_run = OnboardSubscriber.call(user: user, plan: :pro)
# => EasyFlowRun AR record

flow_run.id           # => Integer AR id
flow_run.status       # => 'running', 'succeeded', 'failed', 'cancelled', 'paused'
flow_run.flow_class   # => 'OnboardSubscriber'
flow_run.subject      # => the User AR record (via polymorphic belongs_to)
flow_run.context_data # => serialized ctx (JSON)
```

`.call` and `.call!` behave identically for durable flows — both return `FlowRun`.

## FlowRun lifecycle

```ruby
flow_run.cancel!     # sets status: 'cancelled'; cancels any Scheduler tasks
flow_run.pause!      # sets status: 'paused'
flow_run.resume!     # re-advances from the last completed step index

flow_run.succeeded?  # => true when all steps finished
flow_run.failed?     # => true after an unhandled step failure or explicit cancel!
```

## Execution model

1. `.call(attrs)` → `_start_durable!` → creates `EasyFlowRun` with `status: 'pending'`.
2. `Runner.advance!(flow_run)` runs immediately (same process, same request).
3. For each step:
   - **Sync step**: runs `instance._easyop_run(ctx, raise_on_failure: true)` inline;
     persists ctx to `context_data`; increments `current_step_index`.
   - **Async step**: persists ctx; calls `Easyop::Scheduler.schedule_at(PerformStepOperation,
     run_at, { flow_run_id: })` and **returns immediately** (flow is now suspended).
4. When the Scheduler fires, `PerformStepOperation` calls
   `Runner.execute_scheduled_step!(flow_run)`, which runs the current async step then
   calls `Runner.advance!` to continue.
5. When all steps are done, `status` becomes `'succeeded'`.

## Exception policies

Applied when an **unhandled exception** (not `ctx.fail!`) occurs in a step.
`ctx.fail!` always marks the flow as failed immediately without retrying.

```ruby
flow CreateAccount,
     ChargeCard.on_exception(:cancel!),                         # fail flow on any error
     SendWelcomeEmail.on_exception(:reattempt!, max_reattempts: 3)  # retry up to 3 times
```

| Policy | Behavior |
|--------|----------|
| `:cancel!` (default) | Sets `flow_run.status = 'failed'` immediately |
| `:reattempt!` | Reschedules the failing step via Scheduler; fails after `max_reattempts` total failures |

`max_reattempts` defaults to 3 when not specified.

## `async_retry` — operation-level retry policy

Declare retry behaviour directly on the **operation class** (not the flow). All durable
flows that include the operation inherit the policy automatically.

```ruby
class SendOrderConfirmation < ApplicationOperation
  # Must re-raise so exceptions reach the runner rather than being converted to ctx.fail!
  rescue_from StandardError { |e| raise e }

  async_retry max_attempts: 3, wait: 5, backoff: :exponential

  def call
    Mailer.deliver_confirmation(ctx.order)
    ctx.confirmation_sent_at = Time.current
  end
end
```

| Option | Default | Notes |
|--------|---------|-------|
| `max_attempts:` | `3` | Total attempts including the first (must be ≥ 1) |
| `wait:` | `0` | Base seconds between attempts (Numeric, Duration, or callable `(attempt) → seconds`) |
| `backoff:` | `:constant` | `:constant`, `:linear`, `:exponential`, or callable |

**Backoff strategies** (attempt is 1-indexed, starting at 1 for the first retry):
- `:constant` — always `wait` seconds
- `:linear` — `wait * attempt` seconds
- `:exponential` — `attempt⁴ + wait + rand(30)` seconds (Sidekiq-style jitter)
- callable — `wait.call(attempt)` seconds

**Precedence:** per-step `.on_exception(:reattempt!, max_reattempts: N)` in the flow
declaration overrides the operation's `async_retry` (call-site wins; existing flows
using `:reattempt!` are unaffected).

**`rescue_from` bypass warning:** A base class that does
`rescue_from StandardError { ctx.fail! }` converts exceptions to `Ctx::Failure` before
the runner can see them. `Ctx::Failure` bypasses `async_retry`. Override in the
operation with `rescue_from StandardError { |e| raise e }` to re-raise.

## `blocking: true` — halt and skip remaining steps on final failure

Set on an individual step in the `flow` declaration. When the step exhausts all retry
attempts (or has `async_retry max_attempts: 1`), every remaining step is recorded as
`'skipped'` in `EasyFlowRunStep` and the flow status becomes `'failed'`.

```ruby
class FulfillOrder < ApplicationOperation
  include Easyop::Flow
  transactional false
  subject :order

  # If confirmation fails all 3 async_retry attempts, reminder + survey are skipped
  flow SendOrderConfirmation.async(blocking: true),
       SendEventReminder.async(wait: 24.hours),
       SendPostEventSurvey.async(wait: 48.hours)
end
```

Without `blocking: true`, the flow also fails but subsequent steps leave no
`EasyFlowRunStep` rows at all (incomplete audit trail).

`ctx.fail!` (deliberate failure) also respects `blocking:` — remaining steps are
recorded as `'skipped'` — but does NOT trigger retries.

**Mode-2 guard:** `.async(blocking: true)` in a flow without `subject` raises
`Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError` immediately.

## `subject` precedence rule

`_resolved_subject` returns the effective subject key used when creating the `FlowRun`.
It follows this precedence:

1. Own `subject` declaration on the flow class.
2. First durable sub-flow found by depth-first search through `_flow_steps`.

```ruby
class Inner
  include Easyop::Flow
  subject :account
  flow StepA, StepB
end

class Outer
  include Easyop::Flow
  flow Op1, Inner, Op2   # no own subject; adopts :account from Inner
end

Outer._resolved_subject   # => :account
```

## Free composition matrix

| Outer mode | Inner type | Result |
|------------|-----------|--------|
| Mode 1 or 2 | Mode-1/2 sub-flow | Sub-flow runs as a single inline step |
| Mode 1 or 2 | Durable (Mode-3) sub-flow | Sub-flow steps **flattened** into outer; outer auto-promotes to Mode 3 |
| Mode 3 | Any | All steps merged via `_resolved_flow_steps` |
| Any | Durable sub-flow wrapped in `.skip_if` / `.async` | Raises `ConditionalDurableSubflowNotSupportedError` |
| Any | Whole flow wrapped in `.async(wait:)` | Raises `AsyncFlowEmbeddingNotSupportedError` |

## Error classes

| Class | Fix |
|-------|-----|
| `Easyop::Flow::DurableSupportNotLoadedError` | Add `require "easyop/persistent_flow"` to initializer |
| `Easyop::Flow::AsyncFlowEmbeddingNotSupportedError` | Replace `Inner.async(wait:)` with `Easyop::Scheduler.schedule_at(Inner, ...)` |
| `Easyop::Flow::ConditionalDurableSubflowNotSupportedError` | Wrap the durable sub-flow in a plain operation that calls `.call(ctx.to_h)` |
| `Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError` | `.on_exception` / `.tags` used in a non-durable flow — add `subject` to make it durable |

## Testing durable flows

`include Easyop::Testing` auto-includes `PersistentFlowAssertions` when
`Easyop::PersistentFlow` is defined.

### Minitest pattern

```ruby
class OnboardSubscriberTest < Minitest::Test
  include Easyop::Testing

  def setup
    @user = User.create!(email: 'alice@example.com')
  end

  def test_onboarding_succeeds
    run = OnboardSubscriber.call(user: @user, plan: :pro)

    # Advance all async steps without real Scheduler delays
    speedrun_flow(run)

    assert_flow_status    run, :succeeded
    assert_step_completed run, SendWelcomeEmail
    assert_step_completed run, SendNudge
  end

  def test_nudge_skipped_when_flag_set
    run = OnboardSubscriber.call(user: @user, plan: :pro, skip_nudge: true)
    speedrun_flow(run)

    assert_flow_status  run, :succeeded
    assert_step_skipped run, SendNudge
  end
end
```

### Available assertions

| Helper | Description |
|--------|-------------|
| `speedrun_flow(flow_run)` | Advances all async steps synchronously without real delays |
| `assert_flow_status(run, status)` | Assert `flow_run.status` matches `:succeeded`, `:failed`, etc. |
| `assert_step_completed(run, OpClass)` | Assert a step has a `completed` record |
| `assert_step_skipped(run, OpClass)` | Assert a step has a `skipped` record |
| `assert_step_failed(run, OpClass)` | Assert a step has a `failed` record |

### Using FakeFlowRun stubs in unit tests

For lower-level tests that do not need a real database, build minimal AR-like
doubles and pass them to `Runner` methods directly:

```ruby
# Fake flow_run with just the columns Runner reads/writes
fake_run = Struct.new(
  :id, :flow_class, :context_data, :status, :current_step_index,
  keyword_init: true
) do
  def update_columns(attrs) = attrs.each { |k, v| send(:"#{k}=", v) }
  def reload = self
end.new(
  id:                  1,
  flow_class:          'OnboardSubscriber',
  context_data:        Easyop::Scheduler::Serializer.serialize({ user_id: 42 }),
  status:              'pending',
  current_step_index:  0
)

Easyop::PersistentFlow::Runner.advance!(fake_run)
assert_equal 'succeeded', fake_run.status
```

## Deprecations (removed in v0.6)

| Deprecated | Use instead |
|------------|-------------|
| `include Easyop::PersistentFlow` | `include Easyop::Flow` + `subject :foo` |
| `.start!(attrs)` | `.call(attrs)` |
