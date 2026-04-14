---
name: easyop
description: >
  This skill should be used when the user asks to "create an operation", "add an
  operation", "use easyop", "replace a service object with an operation", "compose
  operations into a flow", "use Easyop::Flow", "use ctx.fail!", "use prepare",
  "add before/after hooks to an operation", "rescue exceptions in an operation",
  "add typed params to an operation", "use skip_if", "add rollback to a flow step",
  "how is easyop different from interactor", "use plugins", "add instrumentation to
  operations", "record operation executions", "run operations in background",
  "wrap operation in transaction", "build a custom plugin", "emit domain events",
  "subscribe to domain events", "publish domain events from an operation", "use
  Easyop::Plugins::Events", "use Easyop::Plugins::EventHandlers", "use event bus",
  "use easyop events", "handle domain events with easyop", or when working with the
  easyop gem in any Ruby or Rails project. Also activate when the user wants to
  implement the operation/command/service-object pattern, wrap business logic in a
  testable object, chain operations in sequence, register callbacks before
  executing a flow, or wire domain events between decoupled operations.
version: 0.1.4
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
Adds `.call_async(attrs, wait:, wait_until:, queue:)`. Serializes AR objects by ID.

```ruby
MyOp.call_async(user: @user, amount: 100)          # enqueue now
MyOp.call_async(user: @user, wait: 5.minutes)      # enqueue with delay
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
- **`references/flow.md`** — Flow, FlowBuilder, skip_if, rollback, guards
- **`references/hooks-and-rescue.md`** — Hooks and rescue_from deep-dive
- **`references/plugins.md`** — All plugins: Instrumentation, Recording, Async, Transactional, Events, EventHandlers, custom
- **`examples/basic_operation.rb`** — Single operation patterns
- **`examples/flow.rb`** — Flow composition patterns
- **`examples/rails_controller.rb`** — Rails controller integration
- **`examples/testing.rb`** — RSpec test patterns
- **`examples/plugins.rb`** — All plugins: Instrumentation, Recording, Async, Transactional, Events, EventHandlers, Bus::Adapter (LoggingBus + full RabbitMQ example)

---
