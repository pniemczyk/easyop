---
name: easyop
description: Use when working with the easyop gem — operations, flows, ctx.fail!, hooks, schema DSL, skip_if, rollback, plugins (Recording, Async, Transactional, Events), or the Ruby service-object / command pattern.
version: 0.5.0
---

# EasyOp Skill

`easyop` wraps business logic in composable, testable operation objects that share
a single `ctx` (context). Operations succeed or fail explicitly — no exceptions
leak to the caller, no mutable global state.

## What It Does

```ruby
# Without EasyOp — scattered, hard to test
def create_user(params)
  user = User.new(params)
  raise "invalid" unless user.valid?
  user.save!
  UserMailer.welcome(user).deliver_later
  user
end

# With EasyOp — explicit, composable, testable
class CreateUser
  include Easyop::Operation

  def call
    ctx.user = User.create!(ctx.slice(:name, :email, :plan))
    UserMailer.welcome(ctx.user).deliver_later
  end
end

result = CreateUser.call(name: "Alice", email: "alice@example.com", plan: "free")
result.success?  # => true
result.user      # => #<User ...>
```

## Core: Single Operation

```ruby
class AuthenticateUser
  include Easyop::Operation

  def call
    user = User.authenticate(ctx.email, ctx.password)
    ctx.fail!(error: "Invalid credentials") unless user
    ctx.user = user
  end
end

# .call — never raises, returns ctx
result = AuthenticateUser.call(email: email, password: password)
result.success?  # => true / false
result.user      # => User or nil
result.error     # => nil or "Invalid credentials"

# .call! — raises Easyop::Ctx::Failure on failure
ctx = AuthenticateUser.call!(email: email, password: password)
```

## Ctx API

```ruby
# Reading
ctx.email          # method access (method_missing)
ctx[:email]        # hash-style access
ctx.admin?         # predicate: !!ctx[:admin] — false for missing keys, never raises

# Writing
ctx.user  = user
ctx.merge!(user: user, token: "abc")

# Extracting a subset as a plain Hash
ctx.slice(:name, :email, :plan)  # => { name: "Alice", ... }

# Failure
ctx.fail!                           # mark failed
ctx.fail!(error: "Boom!")           # merge attrs, then fail
ctx.fail!(error: "…", errors: {})   # structured errors

# Callbacks (post-call)
result.on_success { |ctx| sign_in(ctx.user) }
result.on_failure { |ctx| flash[:alert] = ctx.error }
```

## Hooks

```ruby
class CreateAccount
  include Easyop::Operation

  before :normalize_email
  after  :send_welcome
  around :with_logging

  def call
    ctx.account = Account.create!(ctx.slice(:email, :name))
  end

  private

  def normalize_email
    ctx.email = ctx.email.to_s.strip.downcase
  end

  def send_welcome
    WelcomeMailer.deliver(ctx.account) if ctx.success?
  end

  def with_logging
    Rails.logger.info "start"
    yield
    Rails.logger.info ctx.success? ? "ok" : ctx.error
  end
end
```

`after` hooks always run (in `ensure`). Around hooks call `yield` or `inner.call`.

## rescue_from

```ruby
class ImportData
  include Easyop::Operation

  rescue_from CSV::MalformedCSVError, with: :handle_csv_error
  rescue_from ActiveRecord::RecordInvalid do |e|
    ctx.fail!(error: e.message, errors: e.record.errors.to_h)
  end

  def call
    rows = CSV.parse(ctx.raw, headers: true)
    rows.each { |row| Record.create!(row.to_h) }
    ctx.imported = rows.size
  end

  private

  def handle_csv_error(e)
    ctx.fail!(error: "Bad CSV: #{e.message}")
  end
end
```

Child class handlers always take priority over parent class handlers.

## Typed Schema (optional)

```ruby
class RegisterUser
  include Easyop::Operation

  params do
    required :email,  String
    required :age,    Integer
    optional :plan,   String,   default: "free"
    optional :admin,  :boolean, default: false
  end

  def call
    ctx.user = User.create!(ctx.slice(:email, :age, :plan))
  end
end
```

Type shorthands: `:boolean`, `:string`, `:integer`, `:float`, `:symbol`, `:any`.

## Flow — Composing Operations

```ruby
class ProcessCheckout
  include Easyop::Flow

  flow ValidateCart,
       ApplyCoupon,       # optional — declares skip_if
       ChargePayment,
       CreateOrder,
       SendConfirmation
end

result = ProcessCheckout.call(user: current_user, cart: current_cart)
result.order  # => #<Order ...>
```

Each step shares the same `ctx`. Failure in any step halts the chain and triggers rollback.

## skip_if — Optional Steps

```ruby
class ApplyCoupon
  include Easyop::Operation

  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    ctx.discount = CouponService.apply(ctx.coupon_code)
  end
end
```

Skipped steps are not added to the rollback list.

## Rollback

```ruby
class ChargePayment
  include Easyop::Operation

  def call
    ctx.charge = Stripe::Charge.create(amount: ctx.total, source: ctx.token)
  end

  def rollback
    Stripe::Refund.create(charge: ctx.charge.id) if ctx.charge
  end
end
```

## `prepare` — Pre-registered Callbacks

**Important:** `flow` only declares steps. Use `prepare` for callbacks.

```ruby
# Block callbacks:
ProcessCheckout.prepare
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| flash[:error] = ctx.error; redirect_back }
  .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])

# Symbol callbacks bound to a Rails controller (self):
ProcessCheckout.prepare
  .bind_with(self)
  .on(success: :order_placed, fail: :checkout_failed)
  .call(user: current_user, cart: current_cart)
```

## Pattern Matching (Ruby 3+)

```ruby
case RegisterUser.call(email: email, password: password)
in { success: true, user: }
  sign_in(user)
in { success: false, errors: Hash => errs }
  render :new, locals: { errors: errs }
in { success: false, error: String => msg }
  flash[:error] = msg; render :new
end
```

## Testing (RSpec)

```ruby
RSpec.describe CreateUser do
  it "creates a user" do
    result = described_class.call(name: "Alice", email: "alice@example.com")
    expect(result).to be_success
    expect(result.user).to be_a(User)
  end

  it "fails when email is taken" do
    create(:user, email: "alice@example.com")
    result = described_class.call(name: "Alice", email: "alice@example.com")
    expect(result).to be_failure
    expect(result.error).to include("email")
  end
end
```

## Durable Flows — `subject` Triggers Durability

`Easyop::Flow` auto-detects one of three execution modes:

| Mode | Trigger | Returns |
|------|---------|---------|
| 1 — sync | No `subject`, no `.async` step | `Ctx` (inline) |
| 2 — fire-and-forget async | No `subject`, has `.async` step | `Ctx`; async steps enqueued via `klass.call_async` |
| 3 — durable | **`subject` declared** | `FlowRun` (DB-backed suspend/resume) |

`subject` is the **only** durability trigger. An `.async` step alone (without `subject`) is Mode 2, never Mode 3.

### Mode 2 — fire-and-forget async

```ruby
class RegisterAndNotify
  include Easyop::Flow

  # SendWelcomeEmail must have plugin Easyop::Plugins::Async installed
  flow CreateUser,
       SendWelcomeEmail.async,   # enqueued via call_async — flow continues immediately
       AssignTrial
end

ctx = RegisterAndNotify.call(email: 'a@b.com')  # => Ctx; SendWelcomeEmail in the job queue
ctx.success?  # => true
```

### Mode 3 — durable (suspend-and-resume)

Requires `require "easyop/persistent_flow"` in your initializer (raises
`Easyop::Flow::DurableSupportNotLoadedError` if omitted). Also requires
`require "easyop/scheduler"` for the DB scheduler that drives async steps.

```ruby
# config/initializers/easyop.rb
require 'easyop/scheduler'
require 'easyop/persistent_flow'

class OnboardSubscriber
  include Easyop::Flow

  subject :user   # ← the only durability trigger; binds a polymorphic AR reference

  # SendWelcomeEmail and SendNudge must have plugin Easyop::Plugins::Async installed
  flow CreateAccount,
       SendWelcomeEmail.async,
       SendNudge.async(wait: 3.days)
                .skip_if { |ctx| ctx[:skip_nudge] },
       RecordComplete
end

flow_run = OnboardSubscriber.call(user: user, plan: :pro)
flow_run.id       # => AR id
flow_run.status   # => 'running'
flow_run.subject  # => the User AR record
```

#### Lifecycle controls

```ruby
flow_run.cancel!   # => status: 'cancelled'; cancels any scheduled tasks
flow_run.pause!    # => status: 'paused'
flow_run.resume!   # => re-advances from the last completed step
flow_run.succeeded?
flow_run.failed?
```

#### Exception policies (durable flows only)

```ruby
# These step-builder options require plugin Easyop::Plugins::Async on the operation class
flow CreateAccount,
     ChargeCard.on_exception(:cancel!),                              # fail flow on any error
     SendWelcomeEmail.on_exception(:reattempt!, max_reattempts: 3)  # retry up to 3 times
```

### Free composition — durable sub-flows promote outer

When an outer flow embeds a durable (subject-bearing) sub-flow, the sub-flow's
steps are **flattened** into the outer's `_resolved_flow_steps`, auto-promoting
the outer to Mode 3:

```ruby
class InnerDurable
  include Easyop::Flow
  subject :user
  flow StepA, StepB.async(wait: 1.day)
end

class Outer
  include Easyop::Flow
  flow Op1, InnerDurable, Op2   # Outer auto-promotes to Mode 3
end

run = Outer.call(user: user)    # => FlowRun (not Ctx)
```

Mode-2 (async-only) sub-flows stay encapsulated as a single step — they do **not**
promote the outer to Mode 3.

### New error classes (v0.5)

| Error | When raised |
|-------|-------------|
| `Easyop::Flow::DurableSupportNotLoadedError` | `subject` declared but `require "easyop/persistent_flow"` was not called |
| `Easyop::Flow::AsyncFlowEmbeddingNotSupportedError` | A whole flow class is wrapped in `.async` (e.g. `Inner.async(wait:)`) — use `Easyop::Scheduler.schedule_at` instead |
| `Easyop::Flow::ConditionalDurableSubflowNotSupportedError` | A `StepBuilder` modifier (`.skip_if`, `.async`, etc.) wraps a durable sub-flow |
| `Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError` | `.on_exception` or `.tags` used in a non-durable (Mode 1/2) flow |

### Deprecations (removed in v0.6)

- `include Easyop::PersistentFlow` — use `include Easyop::Flow` + `subject :foo`
- `.start!(attrs)` — use `.call(attrs)`

### Testing durable flows

```ruby
include Easyop::Testing   # auto-includes PersistentFlowAssertions

def test_onboarding_flow
  run = OnboardSubscriber.call(user: user, plan: :pro)

  speedrun_flow(run)   # advances all async steps without real delays

  assert_flow_status    run, :succeeded
  assert_step_completed run, SendWelcomeEmail
  assert_step_completed run, SendNudge
  assert_step_skipped   run, SendNudge   # if ctx[:skip_nudge] was true
end
```

AR model setup via `rails g easyop:install` — generates migrations for
`easy_flow_runs` and `easy_flow_run_steps` tables plus the two model files.

---

## Plugins (opt-in)

All plugins are opt-in. Require and activate:

```ruby
require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/async"
require "easyop/plugins/transactional"

class ApplicationOperation
  include Easyop::Operation

  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording,    model: OperationLog
  plugin Easyop::Plugins::Async,        queue: "operations"
  plugin Easyop::Plugins::Transactional
end
```

### Instrumentation
Fires `"easyop.operation.call"` via `ActiveSupport::Notifications`.
`Easyop::Plugins::Instrumentation.attach_log_subscriber` — one-line Rails logger integration.

### Recording
Persists each execution to an AR model. `recording false` to opt out.
Required columns: `operation_name`, `success`, `error_message`, `params_data`, `duration_ms`, `performed_at`.
Optional flow-tracing columns: `root_reference_id`, `reference_id`, `parent_operation_name`, `parent_reference_id` — add these to reconstruct the full call tree. All operations in one execution share the same `root_reference_id`; parent/child links are captured via `parent_*` fields. Missing columns are silently skipped (backward-compatible). `Easyop::Flow` automatically forwards parent-tracing ctx to child steps — for the flow to appear in logs as the tree root, inherit from your recorded base class and add `transactional false`.
Optional `result_data :text` column — use the `record_result` DSL to selectively persist ctx output (attrs form, block form, or symbol/method form). Plugin-level default via `record_result:` install option; class-level DSL overrides it. Backward-compatible — column silently skipped when absent.

### Async

Adds a fluent builder API and classic `.call_async`. Serializes AR objects by ID.

**Operation-level enqueue** (outside a flow):

```ruby
# Fluent (preferred):
Reports::GeneratePDF.async.call(report_id: 123)
Reports::GeneratePDF.async(wait: 10.minutes).call(report_id: 123)
Reports::GeneratePDF.async(queue: :low, wait_until: 1.day.from_now).call(report_id: 123)

# Classic (still works — zero deprecation pressure):
MyOp.call_async(user: @user, amount: 100)
MyOp.call_async(user: @user, wait: 5.minutes)
```

**Step-builder DSL in flow declarations** — the fluent chain methods (`.async`,
`.skip_if`, `.skip_unless`, `.on_exception`, `.tags`, `.wait`) are available on
any operation class **only after** `plugin Easyop::Plugins::Async` is installed on
that class (or a parent it inherits from). An operation used as a bare step (no
modifiers) inside a `flow` declaration does NOT require the plugin.

```ruby
# ✅ SendWelcomeEmail has plugin Easyop::Plugins::Async — .async is valid
flow CreateUser,
     SendWelcomeEmail.async,
     SendNudge.async(wait: 3.days).skip_if { |ctx| !ctx[:newsletter] },
     RecordComplete

# ❌ If SendWelcomeEmail does NOT have plugin Easyop::Plugins::Async, calling
#    SendWelcomeEmail.async raises NoMethodError
```

Use the `queue` DSL to declare the default queue on a class without re-declaring the plugin:

```ruby
class Weather::BaseOperation < ApplicationOperation
  queue :weather   # inherited by all Weather subclasses
end

class Weather::CleanupExpiredDays < Weather::BaseOperation
  queue :low_priority   # override at leaf level
end
```

### Transactional
Wraps the full operation in an AR/Sequel transaction. `transactional false` to opt out.

```ruby
class TransferFunds < ApplicationOperation
  plugin Easyop::Plugins::Transactional
end
```

### Events (producer)

Emit domain events after an operation completes. Requires the events infrastructure:

```ruby
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"

class PlaceOrder < ApplicationOperation
  plugin Easyop::Plugins::Events

  emits "order.placed",   on: :success, payload: [:order_id, :total]
  emits "order.failed",   on: :failure, payload: ->(ctx) { { error: ctx.error } }
  emits "order.attempted", on: :always

  def call
    ctx.order_id = Order.create!(ctx.to_h).id
  end
end
```

`emits` options: `on:` (`:success` / `:failure` / `:always`), `payload:` (Proc, Array of ctx keys, or nil for full ctx), `guard:` (optional condition Proc). Events fire in an `ensure` block so they publish even when `call!` raises. Publish failures are swallowed per-declaration and never crash the operation. Declarations are inherited by subclasses.

### EventHandlers (subscriber)

Register an operation as a handler for domain events. Uses `Easyop::Events::Registry` under the hood:

```ruby
require "easyop/plugins/event_handlers"

class SendConfirmation < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "order.placed"

  def call
    event    = ctx.event        # Easyop::Events::Event object
    order_id = ctx.order_id     # payload keys merged into ctx
    OrderMailer.confirm(order_id).deliver_later
  end
end

# Async dispatch (requires Plugins::Async also installed):
class IndexOrder < ApplicationOperation
  plugin Easyop::Plugins::Async,         queue: "indexing"
  plugin Easyop::Plugins::EventHandlers

  on "order.*",      async: true            # matches order.placed, order.failed, …
  on "inventory.**", async: true, queue: "low"  # matches any depth

  def call
    SearchIndex.reindex(ctx.order_id)
  end
end
```

Glob patterns: `"order.*"` matches one segment; `"order.**"` matches any depth.
Registration happens at class-load time. For async handlers, `ctx.event_data` holds a plain Hash (serializable for ActiveJob) instead of an Event object.

### Events Bus

Configure globally before handler classes load:

```ruby
# config/initializers/easyop.rb
Easyop::Events::Registry.bus = :memory           # default — in-process, sync
Easyop::Events::Registry.bus = :active_support   # ActiveSupport::Notifications
Easyop::Events::Registry.bus = MyRabbitBus.new   # custom adapter

# Or via configure block:
Easyop.configure { |c| c.event_bus = :active_support }

# In tests — reset between examples:
Easyop::Events::Registry.reset!
```

**Building a custom bus** — subclass `Easyop::Events::Bus::Adapter`. Inherits glob helpers and adds `_safe_invoke` (call + rescue) and `_compile_pattern` (memoized glob→Regexp):

```ruby
require "easyop/events/bus/adapter"

class LoggingBus < Easyop::Events::Bus::Adapter
  def initialize(inner = Easyop::Events::Bus::Memory.new)
    super(); @inner = inner
  end

  def publish(event)
    Rails.logger.info "[bus] #{event.name} #{event.payload}"
    @inner.publish(event)
  end

  def subscribe(pattern, &block) = @inner.subscribe(pattern, &block)
  def unsubscribe(handle)        = @inner.unsubscribe(handle)
end

Easyop::Events::Registry.bus = LoggingBus.new
```

For duck-typed adapters (no subclassing), pass any object with `#publish` and `#subscribe` — Registry auto-wraps it in `Bus::Custom`.

### Custom plugins

```ruby
module MyPlugin < Easyop::Plugins::Base
  def self.install(base, **options)
    base.prepend(RunWrapper)
  end

  module RunWrapper
    def _easyop_run(ctx, raise_on_failure:)
      # before
      result = super
      # after — ctx.success? is final here
      result
    end
  end
end

class ApplicationOperation
  include Easyop::Operation
  plugin MyPlugin, option: :value
end
```

## Additional Resources

- **`references/ctx.md`** — Complete Ctx API
- **`references/operations.md`** — All Operation DSL options
- **`references/flow.md`** — Flow, FlowBuilder, skip_if, rollback, lambda guards, three-mode dispatch
- **`references/durability.md`** — Durable flows deep-dive: setup, subject, runner, exception policies, testing
- **`references/hooks-and-rescue.md`** — Hooks and rescue_from deep-dive
- **`references/plugins.md`** — All plugins: Instrumentation, Recording, Async, Transactional, Events, EventHandlers, custom
- **`examples/basic_operation.rb`** — Single operation patterns
- **`examples/flow.rb`** — Flow composition patterns
- **`examples/rails_controller.rb`** — Rails controller integration
- **`examples/testing.rb`** — RSpec test patterns
- **`examples/plugins.rb`** — All plugins: Instrumentation, Recording, Async, Transactional, Events, EventHandlers, Bus::Adapter (LoggingBus + full RabbitMQ example)

---
