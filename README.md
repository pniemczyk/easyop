# EasyOp

[![Docs](https://img.shields.io/badge/docs-pniemczyk.github.io%2Feasyop-blue)](https://pniemczyk.github.io/easyop/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Changelog](https://img.shields.io/badge/changelog-CHANGELOG.md-orange)](CHANGELOG.md)

**[📖 Documentation](https://pniemczyk.github.io/easyop/)** &nbsp;|&nbsp; **[GitHub](https://github.com/pniemczyk/easyop)** &nbsp;|&nbsp; **[Changelog](CHANGELOG.md)**

A joyful, opinionated Ruby gem for wrapping business logic in composable operations.

```ruby
class AuthenticateUser
  include Easyop::Operation

  def call
    user = User.authenticate(ctx.email, ctx.password)
    ctx.fail!(error: "Invalid credentials") unless user
    ctx.user = user
  end
end

result = AuthenticateUser.call(email: "alice@example.com", password: "hunter2")
result.success?  # => true
result.user      # => #<User ...>
```

## Installation

```ruby
# Gemfile
gem "easyop"
```

```
bundle install
```

## Quick Start

Every operation:
- includes `Easyop::Operation`
- defines a `call` method that reads/writes `ctx`
- returns `ctx` from `.call` — the shared data bag that doubles as the result object

```ruby
class DoubleNumber
  include Easyop::Operation

  def call
    ctx.fail!(error: "input must be a number") unless ctx.number.is_a?(Numeric)
    ctx.result = ctx.number * 2
  end
end

result = DoubleNumber.call(number: 21)
result.success?  # => true
result.result    # => 42

result = DoubleNumber.call(number: "oops")
result.failure?  # => true
result.error     # => "input must be a number"
```

---

## The `ctx` Object

`ctx` is the shared data bag — a Hash-backed object with method-style attribute access. It is passed in from the caller and returned as the result.

```ruby
# Reading
ctx.email           # method access
ctx[:email]         # hash-style access
ctx.admin?          # predicate: !!ctx[:admin]
ctx.key?(:email)    # explicit existence check (true/false)

# Writing
ctx.user  = user
ctx[:user] = user
ctx.merge!(user: user, token: "abc")

# Extracting a subset
ctx.slice(:name, :email)  # => { name: "Alice", email: "alice@example.com" }
ctx.to_h                  # => plain Hash copy of all attributes

# Status
ctx.success?   # true unless fail! was called
ctx.ok?        # alias for success?
ctx.failure?   # true after fail!
ctx.failed?    # alias for failure?

# Fail fast
ctx.fail!                        # mark failed
ctx.fail!(error: "Bad input")    # merge attrs then fail
ctx.fail!(error: "Validation failed", errors: { email: "is blank" })

# Error helpers
ctx.error   # => ctx[:error]
ctx.errors  # => ctx[:errors] || {}
```

### `Ctx::Failure` exception

`ctx.fail!` raises `Easyop::Ctx::Failure`, a `StandardError` subclass. The exception's `.ctx` attribute holds the failed context, and `.message` is formatted as:

```
"Operation failed"               # when ctx.error is nil
"Operation failed: <ctx.error>"  # when ctx.error is set
```

```ruby
begin
  AuthenticateUser.call!(email: email, password: password)
rescue Easyop::Ctx::Failure => e
  e.ctx.error   # => "Invalid credentials"
  e.message     # => "Operation failed: Invalid credentials"
end
```

### Rollback tracking (`called!` / `rollback!`)

These methods are used internally by `Easyop::Flow` to track which operations have run and to roll them back on failure. You generally do not call them directly, but they are part of the public `Ctx` API:

```ruby
ctx.called!(operation_instance)  # register an operation as having run
ctx.rollback!                    # roll back all registered operations in reverse order
```

`rollback!` is idempotent — calling it more than once has no additional effect.

### Chainable callbacks (post-call)

```ruby
AuthenticateUser.call(email: email, password: password)
  .on_success { |ctx| sign_in(ctx.user) }
  .on_failure { |ctx| flash[:alert] = ctx.error }
```

### Pattern matching (Ruby 3+)

```ruby
case AuthenticateUser.call(email: email, password: password)
in { success: true, user: }
  sign_in(user)
in { success: false, error: }
  flash[:alert] = error
end
```

### Bang variant

```ruby
# .call  — returns ctx, swallows failures (check ctx.failure?)
# .call! — returns ctx on success, raises Easyop::Ctx::Failure on failure

begin
  ctx = AuthenticateUser.call!(email: email, password: password)
rescue Easyop::Ctx::Failure => e
  e.ctx.error  # => "Invalid credentials"
end
```

---

## Hooks

```ruby
class NormalizeEmail
  include Easyop::Operation

  before :strip_whitespace
  after  :log_result
  around :with_timing

  def call
    ctx.normalized = ctx.email.downcase
  end

  private

  def strip_whitespace
    ctx.email = ctx.email.to_s.strip
  end

  def log_result
    Rails.logger.info "Normalized: #{ctx.normalized}" if ctx.success?
  end

  def with_timing
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Rails.logger.info "Took #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)}ms"
  end
end
```

Multiple hooks run in declaration order. `after` hooks always run (even on failure). Hooks can be method names (Symbol) or inline blocks:

```ruby
before { ctx.email = ctx.email.to_s.strip.downcase }
after  { Rails.logger.info ctx.inspect }
around { |inner| Sentry.with_scope { inner.call } }
```

---

## `rescue_from`

Handle exceptions without polluting `call` with begin/rescue blocks:

```ruby
class ParseJson
  include Easyop::Operation

  rescue_from JSON::ParserError do |e|
    ctx.fail!(error: "Invalid JSON: #{e.message}")
  end

  def call
    ctx.parsed = JSON.parse(ctx.raw)
  end
end
```

Multiple handlers and `with:` method reference syntax:

```ruby
class ImportData
  include Easyop::Operation

  rescue_from CSV::MalformedCSVError, with: :handle_bad_csv
  rescue_from ActiveRecord::RecordInvalid do |e|
    ctx.fail!(error: e.message, errors: e.record.errors.to_h)
  end

  def call
    # ...
  end

  private

  def handle_bad_csv(e)
    ctx.fail!(error: "CSV is malformed: #{e.message}")
  end
end
```

Handlers are checked in reverse inheritance order — child class handlers take priority over parent class handlers.

---

## Typed Input/Output Schemas

Schemas are optional. Declare them to get early validation and inline documentation:

```ruby
class RegisterUser
  include Easyop::Operation

  params do
    required :email,    String
    required :age,      Integer
    optional :plan,     String,   default: "free"
    optional :admin,    :boolean, default: false
  end

  result do
    required :user, User
  end

  def call
    ctx.user = User.create!(ctx.slice(:email, :age, :plan))
  end
end

result = RegisterUser.call(email: "alice@example.com", age: 30)
result.success?  # => true
result.plan      # => "free"  (default applied)

result = RegisterUser.call(email: "bob@example.com")
result.failure?  # => true
result.error     # => "Missing required params field: age"
```

### Type shorthands

| Symbol | Resolves to |
|--------|------------|
| `:boolean` | `TrueClass \| FalseClass` |
| `:string` | `String` |
| `:integer` | `Integer` |
| `:float` | `Float` |
| `:symbol` | `Symbol` |
| `:any` | any value |

Pass any Ruby class directly: `required :user, User`.

### `inputs` / `outputs` aliases

`inputs` is an alias for `params`, and `outputs` is an alias for `result`. They are interchangeable:

```ruby
class NormalizeAddress
  include Easyop::Operation

  inputs do
    required :street, String
    required :city,   String
  end

  outputs do
    required :formatted, String
  end

  def call
    ctx.formatted = "#{ctx.street}, #{ctx.city}"
  end
end
```

### Configuration

All options are set via `Easyop.configure` in an initializer:

```ruby
# config/initializers/easyop.rb
Easyop.configure do |c|
  # ── Schema validation ────────────────────────────────────────────────────────
  c.strict_types = false    # true  → ctx.fail! on type mismatch
                            # false → warn and continue (default)
  c.type_adapter = :native  # :none | :native (default) | :literal | :dry | :active_model

  # ── Recording plugin — global filter / encrypt lists ─────────────────────────
  # Applied to every operation that has the Recording plugin installed.
  c.recording_filter_keys  = [:internal_token, /secret/i]   # redact these keys
  c.recording_encrypt_keys = [:stripe_token, /card/i]        # encrypt these keys

  # ── Recording plugin — encryption secret ─────────────────────────────────────
  # Required when using encrypt_params / recording_encrypt_keys.
  # Must be ≥ 32 bytes. See "Supplying the encryption secret" below.
  c.recording_secret = ENV["EASYOP_RECORDING_SECRET"]

  # ── Events bus ───────────────────────────────────────────────────────────────
  c.event_bus = :memory           # :memory (default) | :active_support | custom adapter
end
```

Reset to defaults (useful in tests):

```ruby
Easyop.reset_config!
```

#### Supplying the encryption secret

`c.recording_secret` accepts any string ≥ 32 bytes. When it is `nil` or blank, `Easyop::SimpleCrypt` walks the following priority chain at encrypt time and uses the **first non-blank value** it finds — so you only need to configure **one** source:

| Priority | Source | When to use |
|----------|--------|-------------|
| 1 (highest) | `c.recording_secret = "…"` | explicit code — dev overrides, tests |
| 2 | `ENV["EASYOP_RECORDING_SECRET"]` | env var, Docker secret, CI pipeline |
| 3 | `credentials.easyop.recording_secret` | nested Rails credentials namespace |
| 4 | `credentials.easyop_recording_secret` | flat Rails credentials key |
| 5 (lowest) | `credentials.secret_key_base` | automatic fallback — dev/test zero-config |

**Option 1 — explicit config (highest priority)**

Useful in tests and simple setups. Avoid hardcoding a real secret in source code.

```ruby
Easyop.configure do |c|
  c.recording_secret = "a" * 32   # test stub
end
```

**Option 2 — environment variable**

Recommended for containers, Heroku, and 12-factor deployments.

```sh
# Generate a key:
openssl rand -hex 32
# → e.g. "a3f9c2…" (64 hex chars = 32 bytes)
```

```ruby
Easyop.configure do |c|
  c.recording_secret = ENV["EASYOP_RECORDING_SECRET"]
end
```

**Option 3 — nested Rails credentials** *(recommended for Rails apps)*

```sh
rails credentials:edit
```

```yaml
# config/credentials.yml.enc
easyop:
  recording_secret: "<openssl rand -hex 32>"
```

```ruby
Easyop.configure do |c|
  c.recording_secret = Rails.application.credentials.dig(:easyop, :recording_secret)
end
```

**Option 4 — flat Rails credentials key**

```yaml
# config/credentials.yml.enc
easyop_recording_secret: "<openssl rand -hex 32>"
```

```ruby
Easyop.configure do |c|
  c.recording_secret = Rails.application.credentials.easyop_recording_secret
end
```

**Option 5 — auto-resolve (leave `recording_secret` unset)**

When `recording_secret` is not set, `Easyop::SimpleCrypt` resolves the secret automatically each time it encrypts. In development and test Rails apps it falls back to `credentials.secret_key_base`, so encryption works with zero extra setup.

```ruby
Easyop.configure do |c|
  # recording_secret intentionally omitted — SimpleCrypt auto-resolves
  c.strict_types = false
end
```

> **Production note:** never rely solely on `secret_key_base` (option 5) in production. If you ever rotate the app secret, encrypted values stored in `params_data` / `result_data` become permanently unreadable. Use option 2 or 3 with a dedicated, independently-rotatable secret.

**Combining ENV with a Rails credentials fallback:**

```ruby
Easyop.configure do |c|
  c.recording_secret =
    ENV["EASYOP_RECORDING_SECRET"] ||
    Rails.application.credentials.dig(:easyop, :recording_secret) ||
    Rails.application.credentials.easyop_recording_secret
end
```

---

## Flow — Composing Operations

`Easyop::Flow` runs operations in sequence, sharing one `ctx`. Any failure halts the chain.

```ruby
class ProcessCheckout
  include Easyop::Flow

  flow ValidateCart,
       ApplyCoupon,
       ChargePayment,
       CreateOrder,
       SendConfirmation
end

result = ProcessCheckout.call(user: current_user, cart: current_cart)
result.success?  # => true
result.order     # => #<Order ...>
```

### Rollback

Each step can define `rollback`. On failure, rollback runs on all completed steps in reverse:

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

### `skip_if` — Optional steps

Declare when a step should be bypassed:

```ruby
class ApplyCoupon
  include Easyop::Operation

  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    ctx.discount = CouponService.apply(ctx.coupon_code)
  end
end

class ProcessCheckout
  include Easyop::Flow

  flow ValidateCart,
       ApplyCoupon,      # automatically skipped when no coupon_code
       ChargePayment,
       CreateOrder
end
```

Skipped steps are never added to the rollback list.

> **Note:** `skip_if` is evaluated by the Flow runner. Calling an operation directly (e.g. `MyOp.call(...)`) bypasses the skip check entirely — `skip_if` is a Flow concept, not an operation-level guard.

### Lambda guards (inline)

Place a lambda immediately before a step to gate it:

```ruby
flow ValidateCart,
     ->(ctx) { ctx.coupon_code? }, ApplyCoupon,
     ChargePayment
```

### Nested flows

A Flow can be a step inside another Flow:

```ruby
class ProcessOrder
  include Easyop::Flow
  flow ValidateCart, ChargePayment
end

class FullCheckout
  include Easyop::Flow
  flow ProcessOrder, SendConfirmation, NotifyAdmin
end
```

### Recording plugin integration — full call-tree tracing

When step operations have the Recording plugin installed, `Easyop::Flow` automatically forwards the parent-tracing ctx so every step's log entry shows the flow as its `parent_operation_name`. All steps and the flow share the same `root_reference_id`.

**Bare flow** (Recording only on steps — flow is NOT recorded itself, but steps carry correct parent info):

```ruby
class ProcessCheckout
  include Easyop::Flow
  flow ValidateCart, ChargePayment, CreateOrder
end
```

**Recommended** — inherit from your recorded base class so the **flow itself appears in operation_logs** as the tree root. Add `transactional false` so step-level transactions aren't shadowed by an outer one:

```ruby
class ProcessCheckout < ApplicationOperation
  include Easyop::Flow
  transactional false   # EasyOp handles rollback; each step owns its transaction

  flow ValidateCart, ChargePayment, CreateOrder
end
```

Result in `operation_logs`:

```
ProcessCheckout    root=aaa  ref=bbb  parent=nil
  ValidateCart     root=aaa  ref=ccc  parent=ProcessCheckout/bbb
  ChargePayment    root=aaa  ref=ddd  parent=ProcessCheckout/bbb
  CreateOrder      root=aaa  ref=eee  parent=ProcessCheckout/bbb
```

---

## Testing

`Easyop::Testing` is a single include that works in both Minitest and RSpec. It pulls in five assertion modules that cover every part of the library.

```ruby
# Minitest
class MyOpTest < Minitest::Test
  include Easyop::Testing
end

# RSpec
RSpec.describe MyOp do
  include Easyop::Testing
end
```

### Core operation assertions

```ruby
ctx = op_call(RegisterUser, email: 'alice@example.com', name: 'Alice')
assert_op_success ctx
assert_ctx_has    ctx, user_id: 'usr_42'

ctx = op_call(RegisterUser, email: nil)
assert_op_failure ctx
assert_op_failure ctx, error: 'Email is required'
assert_op_failure ctx, error: /required/i
```

| Helper | Description |
|---|---|
| `op_call(Op, **attrs)` | Call op; always returns ctx (never raises) |
| `op_call!(Op, **attrs)` | Call op with `.call!`; raises `Ctx::Failure` on failure |
| `assert_op_success(ctx)` | Assert the ctx is a success |
| `assert_op_failure(ctx, error: nil)` | Assert the ctx is a failure; optionally match error string/regexp |
| `assert_ctx_has(ctx, key: value, ...)` | Assert specific key/value pairs exist in ctx |

**Stubbing operations:**

```ruby
stub_op(Users::Register, success: false, error: 'Already exists') do
  # code under test that calls Users::Register.call(...)
  result = ProcessCheckout.call(user: user, cart: cart)
  assert_op_failure result, error: 'Already exists'
end
```

`stub_op` works with both Minitest (`Object#stub`) and RSpec (`allow().to receive()`).

---

### Recording plugin assertions

Use `Easyop::Testing::FakeModel` as the `model:` argument when installing the Recording plugin in tests. No database required.

```ruby
model = Easyop::Testing::FakeModel.new

class RegisterUser < ApplicationOperation
  plugin Easyop::Plugins::Recording, model: model
  # ...
end

RegisterUser.call(email: 'alice@example.com', password: 'secret')

assert_recorded_success  model
assert_params_recorded   model, :email, 'alice@example.com'
assert_params_filtered   model, :password          # stored as "[FILTERED]"
```

**Encrypted params:**

```ruby
with_recording_secret('a-secret-key-at-least-32-bytes!!') do
  ChargeCard.call(credit_card_number: '4111111111111111', amount_cents: 4999)
  assert_params_encrypted model, :credit_card_number
  card = decrypt_recorded_param(model, :credit_card_number)
  assert_equal '4111111111111111', card
end
```

| Helper | Description |
|---|---|
| `assert_recorded_success(model)` | Assert last record has `success: true` |
| `assert_recorded_failure(model, error: nil)` | Assert last record has `success: false`; optionally match error |
| `assert_params_recorded(model, key, value = any)` | Assert key present in `params_data`; optionally check value |
| `assert_params_filtered(model, *keys)` | Assert keys stored as `"[FILTERED]"` |
| `assert_params_encrypted(model, *keys)` | Assert keys stored as `{"$easyop_encrypted"=>"..."}` marker |
| `assert_params_not_encrypted(model, *keys)` | Assert keys are NOT encrypted |
| `assert_result_recorded(model, key, value = any)` | Assert key present in `result_data`; optionally check value |
| `assert_ar_ref_in_params(model, key, class_name:, id: nil)` | Assert AR object serialized as `{class, id}` in params |
| `assert_ar_ref_in_result(model, key, class_name:, id: nil)` | Assert AR object serialized as `{class, id}` in result |
| `decrypt_recorded_param(model, key)` | Decrypt and return plaintext for an encrypted param |
| `with_recording_secret(secret) { }` | Set recording secret for the duration of a block |

`FakeModel` also exposes `model.last`, `model.last_params`, `model.last_result`, `model.records_for("OpName")`, `model.params_at(i)`, `model.result_at(i)`, and `model.clear!`.

---

### Async plugin assertions

```ruby
calls = capture_async do
  Newsletter::SendBroadcast.async.call(email: 'alice@example.com')
end

assert_async_enqueued calls, Newsletter::SendBroadcast, with: { email: 'alice@example.com' }
assert_async_queue    calls, Newsletter::SendBroadcast, queue: 'default'
```

Use `perform_async_inline` to run async calls synchronously in integration tests:

```ruby
perform_async_inline do
  Newsletter::SendBroadcast.async.call(email: 'alice@example.com')
end
# operation already ran; assert on side effects
```

| Helper | Description |
|---|---|
| `capture_async { }` | Capture `.async.call` / `.call_async` calls without enqueuing; returns array of call hashes |
| `perform_async_inline { }` | Run `.async.call` / `.call_async` calls synchronously (no job queue) |
| `assert_async_enqueued(calls, Op, with: nil)` | Assert op was captured, optionally checking attrs subset |
| `assert_no_async_enqueued(calls, Op = nil)` | Assert no async calls (or none for a specific op) |
| `assert_async_queue(calls, Op, queue:)` | Assert the queue name used |
| `assert_async_wait(calls, Op, wait: nil, wait_until: nil)` | Assert the `wait:` or `wait_until:` value |

Each entry in the `calls` array is `{ operation:, attrs:, queue:, wait:, wait_until: }`.

---

### Events plugin assertions

```ruby
events = capture_events do
  PlaceOrder.call(order_id: 101, amount: 49.95)
end

assert_event_emitted events, 'order.placed'
assert_event_payload events, 'order.placed', order_id: 101, amount: Float
assert_event_source  events, 'order.placed', 'PlaceOrder'
assert_no_events     events, 'order.failed'
```

Pass a specific bus as the first argument to `capture_events` when not using the global registry bus.

| Helper | Description |
|---|---|
| `capture_events(bus = nil) { }` | Subscribe to all events during the block; returns `Event` array |
| `assert_event_emitted(events, name)` | Assert an event with the given name was emitted |
| `assert_no_events(events)` | Assert no events were emitted at all |
| `assert_no_events(events, name)` | Assert a specific event was NOT emitted |
| `assert_event_payload(events, name, **kv)` | Assert payload key/value pairs; values may be Class for type-check |
| `assert_event_source(events, name, source)` | Assert the emitting operation class name |
| `assert_event_on(OpClass, name, :trigger)` | Assert the `:on` trigger declared on the operation (`:success`, `:failure`, `:always`) |

---

## `prepare` — Pre-registered Callbacks

`FlowClass.prepare` returns a `FlowBuilder` that accumulates callbacks before executing the flow. The `flow` class method is reserved for declaring steps — `prepare` is the clear, unambiguous entry point for callback registration.

### Block callbacks

```ruby
ProcessCheckout.prepare
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| flash[:error] = ctx.error; redirect_back }
  .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])
```

### Symbol callbacks with `bind_with`

Bind a host object (e.g. a Rails controller) to dispatch to named methods:

```ruby
# In a Rails controller:
def create
  ProcessCheckout.prepare
    .bind_with(self)
    .on(success: :order_created, fail: :checkout_failed)
    .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])
end

private

def order_created(ctx)
  redirect_to order_path(ctx.order)
end

def checkout_failed(ctx)
  flash[:error] = ctx.error
  render :new
end
```

Zero-arity methods are supported (ctx is not passed):

```ruby
def order_created
  redirect_to orders_path
end
```

### Multiple callbacks

```ruby
ProcessCheckout.prepare
  .on_success { |ctx| Analytics.track("checkout", order_id: ctx.order.id) }
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| Rails.logger.error("Checkout failed: #{ctx.error}") }
  .on_failure { |ctx| render json: { error: ctx.error }, status: 422 }
  .call(attrs)
```

---

## Inheritance — Shared Base Class

```ruby
class ApplicationOperation
  include Easyop::Operation

  rescue_from StandardError do |e|
    Sentry.capture_exception(e)
    ctx.fail!(error: "An unexpected error occurred")
  end
end

class MyOp < ApplicationOperation
  def call
    # StandardError is caught and handled by ApplicationOperation
  end
end
```

---

## Scheduler — Deferred Execution

`Easyop::Scheduler` is a DB-backed scheduler that defers operation execution to a future time. It requires a `easy_scheduled_tasks` table and a recurring `TickJob`.

```ruby
# Gemfile / config/application.rb
require "easyop/scheduler"   # opt-in

# Generate the migration and model:
# bin/rails generate easyop:install --scheduler
```

### One-off scheduling

```ruby
# Schedule 24 hours from now
Easyop::Scheduler.schedule_in(Newsletter::Send, 24.hours, { list_id: 7 })

# Schedule at an exact time
Easyop::Scheduler.schedule_at(Reports::GeneratePDF, Date.tomorrow.noon, { report_id: 1 })

# Tag for grouped cancellation
Easyop::Scheduler.schedule_in(Subscription::Renew, 30.days, { user_id: 42 },
                               tags: ["user:42", "subscription:renewal"])
```

### Cancellation

```ruby
Easyop::Scheduler.cancel(task.id)
Easyop::Scheduler.cancel_by_tag("user:42")
Easyop::Scheduler.cancel_by_operation(Newsletter::Send)
```

### Operation-level plugin

```ruby
class Subscription::Renew < ApplicationOperation
  plugin Easyop::Plugins::Scheduler

  def call; ...; end
end

Subscription::Renew.schedule_in(30.days, user: user)
```

### Testing

```ruby
include Easyop::Testing

def test_renewal_scheduled
  Subscription::Renew.schedule_in(30.days, user: user)
  assert_scheduled Subscription::Renew, tags: ["user:#{user.id}"]
end

def test_flush
  flush_scheduler!   # calls Easyop::Scheduler.tick_now!
end
```

---

## Fluent Async API

`Easyop::Plugins::Async` adds chainable class-level entry points that return an immutable `StepBuilder`. Chain freely — order does not matter; scalars last-write-wins; `:tags` accumulates.

```ruby
# Standalone async enqueue (equivalent to call_async)
Reports::GeneratePDF.async(wait: 5.minutes).call(report_id: 42)

# Inside a flow declaration
flow CreateUser,
     SendWelcomeEmail.async,
     SendNudge.async(wait: 3.days).skip_if { |ctx| !ctx[:newsletter] },
     RecordComplete
```

Available entry points (all return a `StepBuilder`):

| Method | Description |
|---|---|
| `Op.async(**opts)` | Mark async; accepts `wait:`, `queue:` |
| `Op.wait(duration)` | Delay without async flag |
| `Op.skip_if { |ctx| ... }` | Skip when block is truthy (flow only) |
| `Op.skip_unless { |ctx| ... }` | Skip when block is falsy (flow only) |
| `Op.on_exception(policy, **opts)` | Exception policy (durable flow only — when `subject` is declared) |
| `Op.tags(*list)` | Additive tags (durable flow only — when `subject` is declared) |

`wait:`, `wait_until:`, `queue:`, and `at:` are valid in **both** durable (suspend-and-resume) and Mode-2 fire-and-forget flows.

Calling `.call(attrs)` on a builder with durable-only opts raises `PersistentFlowOnlyOptionsError`.

---

## Durable Flows — `subject` Triggers Durability

`Easyop::Flow` supports three execution modes, selected automatically:

| Declaration | Async step semantic | Returns |
|---|---|---|
| No `subject`, no `.async` step | n/a | `Ctx` (sync inline) |
| No `subject`, has `.async` step | **Fire-and-forget**: enqueued via `call_async` (ActiveJob); flow continues immediately | `Ctx` |
| **`subject` declared** | **Suspend-and-resume**: ctx persisted, scheduled via DB scheduler, flow halts until scheduled time | `FlowRun` |

`subject` is the **only** durability trigger. An async step on its own (without `subject`) is fire-and-forget, not durable.

### Mode 2 — Fire-and-forget async

The `.async` step is **enqueued** via ActiveJob and the flow moves on immediately to the next step — it does **not** wait for the async step to finish. Steps after `.async` run before the async step completes.

```ruby
class RegisterAndNotify
  include Easyop::Flow

  flow CreateUser,           # 1. runs now, inline
       SendWelcomeEmail.async, # 2. job enqueued — flow does NOT wait
       AssignTrial            # 3. runs now, before SendWelcomeEmail executes
end

# Execution order inside .call:
#   CreateUser runs inline
#   SendWelcomeEmail is pushed to the job queue ← does not block
#   AssignTrial runs inline  ← runs immediately, email not sent yet
#
# Later, in a background worker:
#   SendWelcomeEmail executes
#
ctx = RegisterAndNotify.call(email: "a@b.com")
# ctx is returned now; SendWelcomeEmail may not have run yet
ctx.success?  # => true
```

Use Mode 2 when the async step is a side-effect that does not affect the steps that follow it (sending an email, enqueuing a notification). If steps after it need its result, use Mode 3.

### Mode 3 — Durable suspend-and-resume

With `subject` declared the flow **suspends** at each `.async` step, persists the ctx to the database, and **resumes from that exact point** only after the background job completes. Steps after `.async` do not run until the async step has finished.

```ruby
require "easyop/scheduler"       # prerequisite
require "easyop/persistent_flow" # opt-in; raises DurableSupportNotLoadedError if omitted

class OnboardSubscriber
  include Easyop::Flow

  subject :user   # ← durability trigger; ctx is persisted to DB

  flow CreateAccount,                                    # 1. runs inline
       SendWelcomeEmail.async,                           # 2. flow SUSPENDS here
       SendNudge.async(wait: 3.days)
                .skip_if { |ctx| ctx[:skip_nudge] },    # 4. flow SUSPENDS again (3 days later)
       RecordComplete                                    # 5. runs inline after nudge finishes
end

# Execution timeline:
#   .call → CreateAccount runs → flow suspends, job scheduled for SendWelcomeEmail
#   (background job runs) → SendWelcomeEmail executes → flow resumes
#   → flow suspends again, job scheduled 3 days out for SendNudge
#   (3 days later, background job runs) → SendNudge executes → flow resumes
#   → RecordComplete runs inline → flow status: "succeeded"
#
flow_run = OnboardSubscriber.call(user: user, plan: :pro)
flow_run.id       # → AR id
flow_run.status   # → "running" (suspended, waiting for SendWelcomeEmail job)
flow_run.subject  # → the User AR record
```

**Key difference from Mode 2:** In Mode 3, `RecordComplete` runs only after `SendWelcomeEmail` (and `SendNudge`) have actually executed. In Mode 2, `AssignTrial` runs before `SendWelcomeEmail` finishes.

| | Mode 2 (fire-and-forget) | Mode 3 (durable) |
|---|---|---|
| Next step waits for async? | **No** — runs immediately | **Yes** — suspends until job completes |
| Returns | `Ctx` | `FlowRun` (AR model) |
| Ctx persisted to DB? | No | Yes — after every step |
| Requires `subject`? | No | Yes |
| Use when | Async is a side-effect; later steps don't need its result | Later steps depend on async result, or you need retry/resume |

### Lifecycle

```ruby
flow_run.cancel!  # → status: "cancelled", cancels any scheduled tasks
flow_run.pause!   # → status: "paused"
flow_run.resume!  # → re-advances from the last completed step
```

### Exception policies

```ruby
flow CreateAccount,
     ChargeCard.on_exception(:cancel!),                         # fail the flow on any error
     SendWelcomeEmail.on_exception(:reattempt!, max_reattempts: 3)  # retry up to 3 times
```

### Operation-level retry (`async_retry`)

Retry policy belongs on the operation — it knows what's transient. Declare it once; every durable flow that uses the operation inherits it automatically.

```ruby
class Tickets::SendConfirmation < ApplicationOperation
  # Must re-raise so the runner sees the exception (not converted to ctx.fail!)
  rescue_from StandardError { |e| raise e }

  async_retry max_attempts: 3,      # total attempts including the first (1 = no retry)
              wait:         5,       # base delay in seconds
              backoff:      :exponential  # :constant | :linear | :exponential | callable
end
```

| Option | Default | Notes |
|--------|---------|-------|
| `max_attempts:` | `3` | Total attempts including the first (≥ 1) |
| `wait:` | `0` | Base seconds; Numeric, Duration, or callable `(attempt) → seconds` |
| `backoff:` | `:constant` | `:constant`, `:linear`, `:exponential`, or callable |

Backoff strategies (attempt is 1-indexed):
- `:constant` — always `wait` seconds
- `:linear` — `wait * attempt` seconds
- `:exponential` — `attempt⁴ + wait + rand(30)` seconds (Sidekiq-style jitter)
- callable — `wait.call(attempt)` for full control

Precedence: per-step `.on_exception(:reattempt!, ...)` overrides `async_retry` for that usage site, preserving backward compatibility.

> **`rescue_from` bypass:** A base class that does `rescue_from StandardError { ctx.fail! }` converts exceptions to `Ctx::Failure` before the runner can retry them. Override in the operation with `rescue_from StandardError { |e| raise e }` to re-raise so retries kick in.

### Blocking steps (`blocking: true`)

When an async step exhausts its retries (or fails with `ctx.fail!`), pass `blocking: true` at the call site to halt the flow and record every remaining step as `'skipped'`:

```ruby
class Flows::FulfillOrder < ApplicationOperation
  include Easyop::Flow
  subject :order

  flow Tickets::SendConfirmation.async(blocking: true),   # skip the rest if this fails for good
       Tickets::SendReminder.async(wait: 30.minutes),
       Tickets::SendSurvey.async(wait: 7.days)
end
```

This is a **flow-level** call-site decision — the same operation can be blocking in one flow and non-blocking in another. `blocking:` requires a durable flow (`subject` declared); using it in a Mode-2 flow raises `PersistentFlowOnlyOptionsError`.

### Free composition

Any flow can embed other flows in its `flow(...)` declaration. Mode-2 sub-flows run as a single inline step. Durable (subject-bearing) sub-flows are flattened into the outer's step list, auto-promoting the outer to Mode 3:

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

run = Outer.call(user: user)    # → FlowRun
```

### Testing

```ruby
include Easyop::Testing   # includes PersistentFlowAssertions automatically

def test_onboarding_flow
  run = OnboardSubscriber.call(user: user, plan: :pro)

  # Advance all async steps without waiting
  speedrun_flow(run)

  assert_flow_status     run, :succeeded
  assert_step_completed  run, SendWelcomeEmail
  assert_step_completed  run, SendNudge
end
```

### Backward compatibility

`include Easyop::PersistentFlow` and `.start!(attrs)` continue to work as deprecated aliases. They will be removed in v0.6.

---

## Plugins

EasyOp has an opt-in plugin system. Plugins are installed on an operation class (or a shared base class) with the `plugin` DSL. Every subclass inherits the plugins of its parent.

```ruby
class ApplicationOperation
  include Easyop::Operation

  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording, model: OperationLog
  plugin Easyop::Plugins::Async, queue: "operations"
end
```

You can inspect which plugins have been installed on an operation class:

```ruby
ApplicationOperation._registered_plugins
# => [
#      { plugin: Easyop::Plugins::Instrumentation, options: {} },
#      { plugin: Easyop::Plugins::Recording, options: { model: OperationLog } },
#      { plugin: Easyop::Plugins::Async, options: { queue: "operations" } }
#    ]
```

Plugins are **not** required automatically — require the ones you use:

```ruby
require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/async"
```

---

### Plugin: Instrumentation

Emits an `ActiveSupport::Notifications` event after every operation call. Requires ActiveSupport (included with Rails).

```ruby
require "easyop/plugins/instrumentation"

class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Instrumentation
end
```

**Event:** `"easyop.operation.call"`

**Payload:**

| Key | Type | Description |
|---|---|---|
| `:operation` | String | Class name, e.g. `"Users::Register"` |
| `:success` | Boolean | `true` unless `ctx.fail!` was called |
| `:error` | String \| nil | `ctx.error` on failure, `nil` on success |
| `:duration` | Float | Elapsed milliseconds |
| `:ctx` | `Easyop::Ctx` | The result object |

**Subscribe manually:**

```ruby
ActiveSupport::Notifications.subscribe("easyop.operation.call") do |event|
  p = event.payload
  Rails.logger.info "[#{p[:operation]}] #{p[:success] ? 'ok' : 'FAILED'} (#{event.duration.round(1)}ms)"
end
```

**Built-in log subscriber** — add this to an initializer for zero-config logging:

```ruby
# config/initializers/easyop.rb
Easyop::Plugins::Instrumentation.attach_log_subscriber
```

Output format:
```
[EasyOp] Users::Register ok (4.2ms)
[EasyOp] Users::Authenticate FAILED (1.1ms) — Invalid email or password
```

---

### Plugin: Recording

Persists every operation execution to an ActiveRecord model. Useful for audit trails, debugging, and performance monitoring.

```ruby
require "easyop/plugins/recording"

class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Recording, model: OperationLog
end
```

**Options:**

| Option | Default | Description |
|---|---|---|
| `model:` | required | ActiveRecord class to write logs into |
| `record_params:` | `true` | Control params serialization: `false` skips it; `true` uses full ctx; also accepts `{ attrs: }`, `Proc`, or `Symbol` |
| `record_result:` | `false` | Plugin-level default for result capture: `false` skips; `true` uses full ctx; also accepts `{ attrs: }`, `Proc`, or `Symbol` |
| `filter_keys:` | `[]` | Extra keys/patterns to filter in `params_data` (Symbol, String, Regexp) — values replaced with `[FILTERED]` |

**Required model columns:**

```ruby
create_table :operation_logs do |t|
  t.string   :operation_name, null: false
  t.boolean  :success,        null: false
  t.string   :error_message
  t.text     :params_data          # JSON — ctx attrs (sensitive keys replaced with [FILTERED])
  t.float    :duration_ms
  t.datetime :performed_at,   null: false

  # Optional — add when using the record_result DSL to capture output data:
  t.text     :result_data          # JSON — selected ctx keys after the operation runs
end
```

**Optional flow-tracing columns:**

Add these columns to reconstruct the full call tree when nested flows run. They are populated automatically when present — missing columns are silently skipped (backward-compatible):

```ruby
add_column :operation_logs, :root_reference_id,     :string
add_column :operation_logs, :reference_id,          :string
add_column :operation_logs, :parent_operation_name, :string
add_column :operation_logs, :parent_reference_id,   :string

add_index :operation_logs, :root_reference_id
add_index :operation_logs, :reference_id, unique: true
add_index :operation_logs, :parent_reference_id
```

All operations triggered by a single top-level call share the same `root_reference_id`. The `parent_operation_name` and `parent_reference_id` columns link each operation to its direct caller. `Easyop::Flow` automatically forwards these ctx keys to child steps — see the [Flow section](#flow--composing-operations) for how to make the flow itself appear as the tree root. Example (flow with nested steps):

```
FullCheckout      root=aaa  ref=bbb  parent=nil
  AuthAndValidate root=aaa  ref=ccc  parent=FullCheckout/bbb
    AuthUser      root=aaa  ref=ddd  parent=AuthAndValidate/ccc
  ProcessPayment  root=aaa  ref=eee  parent=FullCheckout/bbb
```

Useful model helpers:

```ruby
scope :for_tree, ->(id) { where(root_reference_id: id).order(:performed_at) }
def root?; parent_reference_id.nil?; end

# Fetch the entire execution tree for one top-level call:
root_log = OperationLog.find_by(operation_name: "FullCheckout", parent_reference_id: nil)
OperationLog.for_tree(root_log.root_reference_id)
```

**Filtering params** — sensitive keys are kept in `params_data` but their value is replaced with `"[FILTERED]"`, so the audit log shows which fields were passed without exposing their values. All layers are additive:

1. **Built-in `FILTERED_KEYS`** — always applied: `:password`, `:password_confirmation`, `:token`, `:secret`, `:api_key`
2. **Global config** — applied to every recorded operation:
   ```ruby
   Easyop.configure { |c| c.recording_filter_keys = [:api_token, /token/i] }
   ```
3. **Plugin `filter_keys:` option** — applied to all subclasses that share the plugin install:
   ```ruby
   plugin Easyop::Plugins::Recording, model: OperationLog, filter_keys: [:stripe_secret]
   ```
4. **`filter_params` DSL** — per-class, inheritable, and stackable at any level of the hierarchy:
   ```ruby
   class ApplicationOperation < ...
     filter_params :internal_token, /access.?key/i
   end
   class Payments::ChargeCard < ApplicationOperation
     filter_params :card_number   # stacks on top of parent's list
   end
   ```

Internal tracing keys (`__recording_*`) are always fully removed. ActiveRecord objects are serialized as `{ id:, class: }` rather than their full representation.

**`record_params` DSL — control what goes into `params_data`:**

By default, `params_data` records only the keys that were **present in ctx when the operation was called** (inputs), not values computed during the call body. This means `ctx.user = User.create!(...)` set during `#call` will not appear in `params_data` — use `record_result` to capture output values. FILTERED_KEYS and INTERNAL_CTX_KEYS are always excluded.

Use the `record_params` DSL to further customize or suppress params recording:

```ruby
# Disable entirely — no params_data written
class Users::Authenticate < ApplicationOperation
  record_params false
end

# Selective keys — only these ctx attrs are recorded
class Tickets::GenerateTickets < ApplicationOperation
  record_params attrs: %i[event_id seat_count]
end

# Block — full control over the extracted hash
class Reports::GeneratePdf < ApplicationOperation
  record_params { |ctx| { report_type: ctx.report_type, page_count: ctx.pages } }
end

# Symbol — delegates to a private method on the instance
class Payments::ChargeCard < ApplicationOperation
  record_params :safe_params

  private
  def safe_params
    { user_id: ctx.user.id, amount_cents: ctx.amount_cents }
  end
end
```

FILTERED_KEYS are **always applied** to the extracted hash regardless of form — including custom attrs, blocks, and symbol methods. Plugin install-level `record_params:` accepts the same forms as the DSL.

> **Input vs. output**: The `true` (default) form records only keys present *before* the call body runs — values computed during `#call` (like `ctx.user`) are excluded. Custom forms (attrs, block, symbol) are evaluated *after* the call, so they can access computed values. Use `record_result` to capture outputs alongside inputs.

**`record_result` DSL — capture output data:**

Add an optional `result_data :text` column to persist selected ctx values after the operation runs:

```ruby
add_column :operation_logs, :result_data, :text  # stored as JSON
```

Then declare what to record using the `record_result` DSL (four forms):

```ruby
# True form — full ctx snapshot (FILTERED_KEYS applied, internal keys excluded)
class Users::Register < ApplicationOperation
  record_result true
end

# Attrs form — one or more ctx keys
class PlaceOrder < ApplicationOperation
  record_result attrs: :order_id
end

class ProcessPayment < ApplicationOperation
  record_result attrs: [:charge_id, :amount_cents]
end

# Block form — custom extraction
class GenerateReport < ApplicationOperation
  record_result { |ctx| { rows: ctx.rows.count, format: ctx.format } }
end

# Symbol form — delegates to a private instance method
class BuildInvoice < ApplicationOperation
  record_result :build_result

  private

  def build_result
    { invoice_id: ctx.invoice.id, total: ctx.total }
  end
end
```

Set a plugin-level default inherited by all subclasses:

```ruby
plugin Easyop::Plugins::Recording, model: OperationLog,
       record_result: true
# or: record_result: { attrs: :metadata }
# or: record_result: ->(ctx) { { id: ctx.record_id } }
# or: record_result: :build_result
```

Class-level `record_result` overrides the plugin-level default. Missing ctx keys produce `nil` — no error. The `result_data` column is silently skipped when absent from the model table — fully backward-compatible.

**Opt out per class:**

```ruby
class Newsletter::SendBroadcast < ApplicationOperation
  recording false   # skip logging for this operation
end
```

Recording failures are swallowed and logged as warnings — a failed log write never breaks the operation.

**Encrypted recording (`encrypt_params` DSL):**

Sensitive values (payment tokens, card numbers, PII) can be stored encrypted-at-rest instead of filtered. The gem ships `Easyop::SimpleCrypt`, a thin wrapper around `ActiveSupport::MessageEncryptor`, that converts the value to a `{ "$easyop_encrypted" => "<ciphertext>" }` marker hash written into `params_data` / `result_data`. The original value is recoverable by your application code (e.g. for log-based rollback) while remaining unreadable at the database row level.

**Setup — configure a secret:**

`Easyop::SimpleCrypt` resolves the encryption secret from the **first non-blank source** in this priority chain (you only need to configure one):

| Priority | Source | Notes |
|----------|--------|-------|
| 1 | `Easyop.config.recording_secret` | explicit code config — always wins |
| 2 | `ENV["EASYOP_RECORDING_SECRET"]` | env var / Docker secret / CI pipeline |
| 3 | `credentials.easyop.recording_secret` | nested Rails credentials namespace |
| 4 | `credentials.easyop_recording_secret` | flat Rails credentials key |
| 5 | `credentials.secret_key_base` | app fallback — works out-of-the-box in dev/test |

```ruby
# config/initializers/easyop.rb

# ── Option A: env var (12-factor / containers) ──────────────────────────────
Easyop.configure { |c| c.recording_secret = ENV["EASYOP_RECORDING_SECRET"] }

# ── Option B: nested Rails credentials (recommended for Rails apps) ─────────
# credentials.yml.enc:
#   easyop:
#     recording_secret: <openssl rand -hex 32>
Easyop.configure { |c| c.recording_secret = Rails.application.credentials.dig(:easyop, :recording_secret) }

# ── Option C: flat Rails credentials key ────────────────────────────────────
# credentials.yml.enc:
#   easyop_recording_secret: <openssl rand -hex 32>
Easyop.configure { |c| c.recording_secret = Rails.application.credentials.easyop_recording_secret }

# ── Option D: let the gem auto-resolve at encrypt time ──────────────────────
# Don't set recording_secret at all — SimpleCrypt walks the chain above.
# In development/test it automatically falls back to secret_key_base (#5).
Easyop.configure { |c| } # recording_secret left nil
```

> **Production**: use Option A (env var) or B/C (Rails encrypted credentials). Rotating `secret_key_base` (Option 5 fallback) would break decryption of already-stored values — don't rely on it in production.

**`encrypt_params` DSL** — mirrors `filter_params`, inheritable and stackable:

```ruby
class Payments::ChargeCard < ApplicationOperation
  encrypt_params :credit_card_number, :cvv
end
```

Or set a plugin-level default:

```ruby
plugin Easyop::Plugins::Recording, model: OperationLog,
       encrypt_keys: [:api_key]
```

Or globally:

```ruby
Easyop.configure do |c|
  c.recording_encrypt_keys = [:stripe_token]
end
```

**Precedence** (highest wins):
1. Built-in `FILTERED_KEYS` (`password`, `token`, `secret`, `api_key`, `password_confirmation`) → always `"[FILTERED]"` — cannot be encrypted.
2. `encrypt_params` / `encrypt_keys` / `recording_encrypt_keys` → encrypted marker.
3. `filter_params` / `filter_keys` / `recording_filter_keys` → `"[FILTERED]"`.
4. Everything else → normal serialization (AR objects → `{id:, class:}`, primitives passthrough).

**Decrypting a marker in application code:**

```ruby
# Pass-through for non-encrypted values; decrypts and JSON-parses structured values.
plain = Easyop::SimpleCrypt.decrypt_marker(params["credit_card_number"])
```

**`Easyop::SimpleCrypt` API:**

```ruby
Easyop::SimpleCrypt.encrypt(value)              # → ciphertext string
Easyop::SimpleCrypt.decrypt(ciphertext)         # → original string (raises DecryptionError on tamper)
Easyop::SimpleCrypt.encrypted_marker?(value)    # → true if { "$easyop_encrypted" => ... }
Easyop::SimpleCrypt.decrypt_marker(value)       # → pass-through or decrypted value
```

Errors: `Easyop::SimpleCrypt::MissingSecretError`, `EncryptionError`, `DecryptionError`. Encryption failures store `"[ENCRYPTION_FAILED]"` and log a warning — they never raise from the operation.

---

**Building a log-based rollback (application recipe):**

Once operations record their inputs and outputs via the Recording plugin, you can build compensating transactions that undo a completed flow purely from `OperationLog` data — no live ctx needed.

This is an **application-level feature**, not a gem plugin. The gem provides the building blocks (`SimpleCrypt`, `encrypt_params`, `record_result`); your app provides the rollback service and the `def self.undo(log)` convention.

A full, working implementation is in the example app:
- `examples/easyop_test_app/app/services/log_rollback.rb` — the `LogRollback` service
- `examples/easyop_test_app/app/operations/logs/undo_from_log.rb` — an operation that runs `LogRollback` and records the rollback itself
- `examples/easyop_test_app/app/operations/flows/purchase_access.rb` — a flow with `encrypt_params :credit_card_number` + `def self.undo(log)` that decrypts the card to issue a refund

**Convention: add `def self.undo(log)` to each reversible operation:**

```ruby
class Payments::ChargeCard < ApplicationOperation
  encrypt_params :credit_card_number
  record_result attrs: %i[payment]

  def call
    ctx.payment = Payment.create!(amount: ctx.amount, ...)
  end

  def self.undo(log)
    card    = Easyop::SimpleCrypt.decrypt_marker(log.parsed_params["credit_card_number"])
    payment = Payment.find(log.parsed_result.dig("payment", "id"))
    RefundGateway.refund!(card_number: card, amount: payment.amount)
    payment.update!(refunded_at: Time.current)
  end
end
```

**`LogRollback.undo!` walks the tree in reverse execution order:**

```ruby
# Each step that defines .undo(log) is reversed; others are skipped.
result = LogRollback.undo!(root_log, on_error: :collect, transaction: true)
result.undone   # => [{ log:, operation: }]
result.skipped  # => [{ log:, reason: }]
result.errors   # => [{ log:, error:, cause: }]
```

Options: `on_error: :raise` (default) | `:collect` | `:halt`; `transaction: false`; `allow_partial: false`.

---

### Plugin: Async

Adds async enqueue to any operation class via ActiveJob. Requires ActiveJob (included with Rails).

```ruby
require "easyop/plugins/async"

class Newsletter::SendBroadcast < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "broadcasts"
end
```

#### Enqueueing — fluent form (preferred)

```ruby
Newsletter::SendBroadcast.async.call(subject: "Hello", body: "World")
Newsletter::SendBroadcast.async(wait: 10.minutes).call(subject: "Hello", body: "World")
Newsletter::SendBroadcast.async(wait_until: Date.tomorrow.noon).call(attrs)
Newsletter::SendBroadcast.async(queue: "low_priority").call(attrs)
```

The fluent form returns an `Easyop::Operation::StepBuilder`. Calling `.call(attrs)` on it delegates to `call_async`, so all existing guarantees (serialization, test spy, Recording plugin integration) are preserved.

#### Enqueueing — classic form (still works, no deprecation)

```ruby
Newsletter::SendBroadcast.call_async(subject: "Hello", body: "World")
Newsletter::SendBroadcast.call_async(attrs, wait: 10.minutes)
Newsletter::SendBroadcast.call_async(attrs, wait_until: Date.tomorrow.noon)
Newsletter::SendBroadcast.call_async(attrs, queue: "low_priority")
```

#### `queue` DSL

Declare or override the default queue directly on a class:

```ruby
class Weather::BaseOperation < ApplicationOperation
  queue :weather   # all Weather ops use the "weather" queue by default
end

class Weather::CleanupExpiredDays < Weather::BaseOperation
  queue :low_priority   # override just for this class
end
```

The `queue` setting is inherited by subclasses. A per-call `queue:` argument always takes precedence.

**ActiveRecord objects** are serialized by `(class, id)` and re-fetched in the job:

```ruby
Newsletter::SendBroadcast.async.call(article: @article, subject: "Hello")
# Article serialized as { "__ar_class" => "Article", "__ar_id" => 42 }
```

Only pass serializable values: `String`, `Integer`, `Float`, `Boolean`, `nil`, `Hash`, `Array`, or `ActiveRecord::Base`.

The plugin defines `Easyop::Plugins::Async::Job` lazily (on first call) so you can require the plugin before ActiveJob loads.

---

### Plugin: Events

Emits domain events after an operation completes. Unlike the Instrumentation plugin (which is for operation-level tracing), Events carries business domain events through a configurable bus.

```ruby
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"
require "easyop/plugins/event_handlers"

class PlaceOrder < ApplicationOperation
  plugin Easyop::Plugins::Events

  emits "order.placed", on: :success, payload: [:order_id, :total]
  emits "order.failed", on: :failure, payload: ->(ctx) { { error: ctx.error } }
  emits "order.attempted", on: :always

  def call
    ctx.order_id = Order.create!(ctx.to_h).id
  end
end
```

**`emits` DSL options:**

| Option | Values | Default | Description |
|---|---|---|---|
| `on:` | `:success`, `:failure`, `:always` | `:success` | When to fire |
| `payload:` | `Proc`, `Array`, `nil` | `nil` (full ctx) | Proc receives ctx; Array slices ctx keys |
| `guard:` | `Proc`, `nil` | `nil` | Extra condition — fires only when truthy |

Events fire in an `ensure` block and are emitted even when `call!` raises. Individual publish failures are swallowed and never crash the operation. `emits` declarations are inherited by subclasses.

---

### Plugin: EventHandlers

Wires an operation class as a domain event handler. Handler operations receive `ctx.event` (the `Easyop::Events::Event` object) and all payload keys merged into ctx.

```ruby
class SendConfirmation < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "order.placed"

  def call
    event    = ctx.event      # Easyop::Events::Event
    order_id = ctx.order_id   # payload keys merged into ctx
    OrderMailer.confirm(order_id).deliver_later
  end
end
```

**Async dispatch** (requires `Plugins::Async` also installed):

```ruby
class IndexOrder < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "indexing"
  plugin Easyop::Plugins::EventHandlers

  on "order.*",      async: true
  on "inventory.**", async: true, queue: "low"

  def call
    # ctx.event_data is a Hash when dispatched async (serializable for ActiveJob)
    SearchIndex.reindex(ctx.order_id)
  end
end
```

**Glob patterns:**
- `"order.*"` — matches within one dot-segment (`order.placed`, `order.shipped`)
- `"warehouse.**"` — matches across segments (`warehouse.stock.updated`, `warehouse.zone.moved`)
- Plain strings match exactly; `Regexp` is also accepted

Registration happens at class-load time. Configure the bus **before** loading handler classes.

---

### Events Bus — Configurable Transport

The bus adapter controls how events are delivered. Configure it once at boot:

```ruby
# Default — in-process synchronous (great for tests and simple setups)
Easyop::Events::Registry.bus = :memory

# ActiveSupport::Notifications (integrates with Rails instrumentation)
Easyop::Events::Registry.bus = :active_support

# Any custom adapter (RabbitMQ, Kafka, Redis Pub/Sub…)
Easyop::Events::Registry.bus = MyRabbitBus.new

# Or via config block:
Easyop.configure { |c| c.event_bus = :active_support }
```

**Built-in adapters:**

| Adapter | Class | Notes |
|---|---|---|
| Memory | `Easyop::Events::Bus::Memory` | Default. Thread-safe, in-process, synchronous. |
| ActiveSupport | `Easyop::Events::Bus::ActiveSupportNotifications` | Wraps `AS::Notifications`. Requires `activesupport`. |
| Custom | `Easyop::Events::Bus::Custom` | Wraps any object with `#publish` and `#subscribe`. |

**Building a custom bus — two approaches:**

**Option A — subclass `Bus::Adapter`** (recommended for real transports). Inherits glob helpers, `_safe_invoke`, and `_compile_pattern`:

```ruby
require "easyop/events/bus/adapter"

# Decorator: wraps any inner bus and adds structured logging
class LoggingBus < Easyop::Events::Bus::Adapter
  def initialize(inner = Easyop::Events::Bus::Memory.new)
    super()
    @inner = inner
  end

  def publish(event)
    Rails.logger.info "[bus:publish] #{event.name} payload=#{event.payload}"
    @inner.publish(event)
  end

  def subscribe(pattern, &block) = @inner.subscribe(pattern, &block)
  def unsubscribe(handle)        = @inner.unsubscribe(handle)
end

Easyop::Events::Registry.bus = LoggingBus.new

# Full RabbitMQ example (Bunny gem) — uses _safe_invoke for handler safety:
class RabbitBus < Easyop::Events::Bus::Adapter
  EXCHANGE_NAME = "easyop.events"

  def initialize(url = ENV.fetch("AMQP_URL", "amqp://localhost"))
    super()
    @url = url; @mutex = Mutex.new; @handles = {}
  end

  def publish(event)
    exchange.publish(event.to_h.to_json,
                     routing_key: event.name, content_type: "application/json")
  end

  def subscribe(pattern, &block)
    q = channel.queue("", exclusive: true, auto_delete: true)
    q.bind(exchange, routing_key: _to_amqp(pattern))
    consumer = q.subscribe { |_, _, body| _safe_invoke(block, decode(body)) }
    handle = Object.new
    @mutex.synchronize { @handles[handle.object_id] = { queue: q, consumer: consumer } }
    handle
  end

  def unsubscribe(handle)
    @mutex.synchronize do
      e = @handles.delete(handle.object_id); return unless e
      e[:consumer].cancel; e[:queue].delete
    end
  end

  def disconnect
    @mutex.synchronize { @connection&.close; @connection = @channel = @exchange = nil }
  end

  private

  def _to_amqp(p)  = p.is_a?(Regexp) ? p.source : p.gsub("**", "#")
  def decode(body) = Easyop::Events::Event.new(**JSON.parse(body, symbolize_names: true))
  def connection   = @connection ||= Bunny.new(@url, recover_from_connection_close: true).tap(&:start)
  def channel      = @channel    ||= connection.create_channel
  def exchange     = @exchange   ||= channel.topic(EXCHANGE_NAME, durable: true)
end

Easyop::Events::Registry.bus = RabbitBus.new
at_exit { Easyop::Events::Registry.bus.disconnect }
```

**Option B — duck-typed object** (no subclassing). Pass any object with `#publish` and `#subscribe`; Registry auto-wraps it in `Bus::Custom`:

```ruby
class MyKafkaBus
  def publish(event) = Kafka.produce(event.name, event.to_h.to_json)
  def subscribe(pattern, &block) = Kafka.subscribe(pattern) { |msg| block.call(decode(msg)) }
end

Easyop::Events::Registry.bus = MyKafkaBus.new
```

---

### Plugin: Transactional

Wraps every operation call in a database transaction. On `ctx.fail!` or any unhandled exception the transaction is rolled back. Supports **ActiveRecord** and **Sequel**.

```ruby
require "easyop/plugins/transactional"

# Per operation:
class TransferFunds < ApplicationOperation
  plugin Easyop::Plugins::Transactional

  def call
    ctx.from_account.debit!(ctx.amount)
    ctx.to_account.credit!(ctx.amount)
    ctx.transaction_id = SecureRandom.uuid
  end
end

# Or globally on ApplicationOperation — all subclasses get transactions:
class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Transactional
end
```

Also works with the classic `include` style:

```ruby
class TransferFunds
  include Easyop::Operation
  include Easyop::Plugins::Transactional
end
```

**Opt out** per class when the parent has transactions enabled:

```ruby
class ReadOnlyReport < ApplicationOperation
  transactional false   # no transaction overhead for read-only ops
end
```

**Options:** none — the adapter is detected automatically (ActiveRecord first, then Sequel).

**Placement in the lifecycle:** The transaction wraps the entire `prepare` chain — before hooks, `call`, and after hooks all run inside the same transaction. If `ctx.fail!` is called (raising `Ctx::Failure`), the transaction rolls back.

**With Flow:** When using `Easyop::Plugins::Transactional` inside a Flow step, the transaction is scoped to that one step, not the whole flow. For a flow-wide transaction, include it on the flow class itself.

---

### Building Your Own Plugin

A plugin is any object responding to `.install(base_class, **options)`. Inherit from `Easyop::Plugins::Base` for a clear interface:

```ruby
require "easyop/plugins/base"

module MyPlugin < Easyop::Plugins::Base
  def self.install(base, **options)
    # 1. Prepend a module to wrap _easyop_run (wraps the entire lifecycle)
    base.prepend(RunWrapper)

    # 2. Extend to add class-level DSL
    base.extend(ClassMethods)

    # 3. Store configuration on the class
    base.instance_variable_set(:@_my_plugin_option, options[:my_option])
  end

  module ClassMethods
    # DSL method for subclasses to configure the plugin
    def my_plugin_option(value)
      @_my_plugin_option = value
    end

    def _my_plugin_option
      @_my_plugin_option ||
        (superclass.respond_to?(:_my_plugin_option) ? superclass._my_plugin_option : nil)
    end
  end

  module RunWrapper
    # Override _easyop_run to wrap the full operation lifecycle.
    # Always call super and return ctx.
    def _easyop_run(ctx, raise_on_failure:)
      # before
      puts "Starting #{self.class.name}"

      super.tap do
        # after (ctx is fully settled — success? / failure? are final here)
        puts "Finished #{self.class.name}: #{ctx.success? ? 'ok' : 'FAILED'}"
      end
    end
  end
end
```

**Activate it:**

```ruby
class ApplicationOperation
  include Easyop::Operation
  plugin MyPlugin, my_option: "value"
end
```

**Per-class opt-out pattern** (same pattern used by the Recording plugin):

```ruby
module MyPlugin < Easyop::Plugins::Base
  module ClassMethods
    def my_plugin(enabled)
      @_my_plugin_enabled = enabled
    end

    def _my_plugin_enabled?
      return @_my_plugin_enabled if instance_variable_defined?(:@_my_plugin_enabled)
      superclass.respond_to?(:_my_plugin_enabled?) ? superclass._my_plugin_enabled? : true
    end
  end

  module RunWrapper
    def _easyop_run(ctx, raise_on_failure:)
      return super unless self.class._my_plugin_enabled?
      # ... plugin logic
      super
    end
  end
end

# Then in an operation:
class InternalOp < ApplicationOperation
  my_plugin false
end
```

**Plugin execution order** is determined by the order `plugin` calls appear. Each plugin prepends its `RunWrapper`, so the last plugin installed is the outermost wrapper:

```
Plugin3::RunWrapper  (outermost)
  Plugin2::RunWrapper
    Plugin1::RunWrapper
      prepare { before → call → after }  (innermost)
```

**Naming convention:** prefix all internal instance methods with `_pluginname_` (e.g. `_recording_persist!`, `_async_serialize`) to avoid collisions with application code.

---

## Rails Controller Integration

### Pattern 1 — Inline callbacks

```ruby
class UsersController < ApplicationController
  def create
    CreateUser.call(user_params)
      .on_success { |ctx| redirect_to profile_path(ctx.user) }
      .on_failure { |ctx| render :new, locals: { errors: ctx.errors } }
  end
end
```

### Pattern 2 — `prepare` and `bind_with`

```ruby
class CheckoutsController < ApplicationController
  def create
    ProcessCheckout.prepare
      .bind_with(self)
      .on(success: :checkout_complete, fail: :checkout_failed)
      .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])
  end

  private

  def checkout_complete(ctx)
    redirect_to order_path(ctx.order), notice: "Order placed!"
  end

  def checkout_failed(ctx)
    flash[:error] = ctx.error
    render :new
  end
end
```

### Pattern 3 — Pattern matching

```ruby
def create
  case CreateUser.call(user_params)
  in { success: true, user: }
    redirect_to profile_path(user)
  in { success: false, errors: Hash => errs }
    render :new, locals: { errors: errs }
  in { success: false, error: String => msg }
    flash[:alert] = msg
    render :new
  end
end
```

---

## Full Checkout Example

```ruby
class ValidateCart
  include Easyop::Operation

  def call
    ctx.fail!(error: "Cart is empty") if ctx.cart.items.empty?
    ctx.total = ctx.cart.items.sum(&:price)
  end
end

class ApplyCoupon
  include Easyop::Operation

  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    coupon = Coupon.find_by(code: ctx.coupon_code)
    ctx.fail!(error: "Invalid coupon") unless coupon&.active?
    ctx.total    -= coupon.discount_amount
    ctx.discount  = coupon.discount_amount
  end
end

class ChargePayment
  include Easyop::Operation

  def call
    charge = Stripe::Charge.create(amount: ctx.total, source: ctx.payment_token)
    ctx.charge = charge
  end

  def rollback
    Stripe::Refund.create(charge: ctx.charge.id) if ctx.charge
  end
end

class CreateOrder
  include Easyop::Operation

  def call
    ctx.order = Order.create!(
      user:     ctx.user,
      total:    ctx.total,
      charge:   ctx.charge.id,
      discount: ctx.discount
    )
  end

  def rollback
    ctx.order.destroy! if ctx.order
  end
end

class SendConfirmation
  include Easyop::Operation

  def call
    OrderMailer.confirmation(ctx.order).deliver_later
  end
end

class ProcessCheckout
  include Easyop::Flow

  flow ValidateCart,
       ApplyCoupon,
       ChargePayment,
       CreateOrder,
       SendConfirmation
end

# Controller:
ProcessCheckout.prepare
  .bind_with(self)
  .on(success: :order_created, fail: :checkout_failed)
  .call(
    user:          current_user,
    cart:          current_cart,
    payment_token: params[:stripe_token],
    coupon_code:   params[:coupon_code]
  )
```

---

## Running Examples

`examples/code/` contains self-contained scripts — no Rails, no database — that run with a plain `ruby` invocation:

| File | Feature |
|---|---|
| `01_basic_operation.rb` | `include Easyop::Operation`, `ctx`, `.call` / `.call!` |
| `02_hooks.rb` | `before`, `after`, `around` hooks |
| `03_rescue_from.rb` | `rescue_from` exception handling |
| `04_schema.rb` | `params` / `result` typed schemas |
| `05_flow.rb` | Flow composition, rollback, `skip_if`, lambda guards |
| `06_events.rb` | Events plugin — `emits`, `on`, `capture_events` |
| `07_recording.rb` | Recording plugin — `filter_params`, `encrypt_params`, `record_result` |
```bash
ruby examples/code/01_basic_operation.rb
```

The top-level quick reference:

```
ruby examples/usage.rb
```

## Example Rails Apps

Two full Rails 8 applications live in `/examples/`. Neither is included in the gem — repository only.

### Blog App — `easyop_test_app`

A blog + newsletter app demonstrating the full EasyOp feature set.

| Feature | Where to look |
|---|---|
| Basic operations | `app/operations/users/`, `app/operations/articles/` |
| Typed `params` schema | `app/operations/users/register.rb` |
| `rescue_from` | `app/operations/application_operation.rb` |
| Flow with rollback | `app/operations/flows/transfer_credits.rb` |
| `skip_if` / lambda guards | `Flows::TransferCredits::ApplyFee` |
| Instrumentation plugin | `ApplicationOperation` → `plugin Easyop::Plugins::Instrumentation` |
| Recording plugin | `ApplicationOperation` → persists to `operation_logs` table |
| Async plugin | `app/operations/newsletter/subscribe.rb` |
| Transactional plugin | `ApplicationOperation` → all DB ops wrapped in transactions |
| Rails controller integration | `app/controllers/articles_controller.rb`, `transfers_controller.rb` |

```bash
cd examples/easyop_test_app
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server -p 3002
```

Seed accounts: `alice@example.com` / `password123` (500 credits), `bob`, `carol`, `dave` (0 credits — tests insufficient-funds error).

### TicketFlow — `ticketflow`

A full event ticket-selling platform with modern Tailwind UI and admin panel. Every operation is powered by EasyOp.

| Feature | Where to look |
|---|---|
| Multi-step checkout Flow | `app/operations/flows/checkout.rb` — 6 chained operations |
| `skip_if` (optional discount step) | `app/operations/orders/apply_discount.rb` |
| Rollback on payment failure | `app/operations/orders/process_payment.rb#rollback` |
| `prepare` + callbacks in controller | `app/controllers/checkouts_controller.rb` |
| Recording plugin → operation logs | `app/operations/application_operation.rb` |
| Admin metrics dashboard | `app/controllers/admin/dashboard_controller.rb` |
| Admin order refund operation | `app/operations/admin/refund_order.rb` |
| Virtual ticket generation | `app/operations/tickets/generate_tickets.rb` |

```bash
cd examples/ticketflow
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server -p 3001
```

Seed accounts: `admin@ticketflow.com` / `password123` (admin), `user@ticketflow.com` / `password123` (customer).
Discount codes: `SAVE10` (10% off), `FLAT20` ($20 off), `VIP50` (50% off).

## Running Tests

```
bundle exec rake test
```

---

## Developer Dashboard — `easyop-ui`

[**easyop-ui**](https://github.com/pniemczyk/easyop/tree/main/easyop-ui) is a companion mountable Rails engine that provides a zero-configuration developer dashboard. Add it to any Rails app and open `/easyop` in a browser — no configuration required.

### Features

| Feature | Description |
|---|---|
| **Operation Log Browser** | Paginated table with filters (name, status, date); per-record detail + full call-tree visualization |
| **Flow Registry** | Lists every `Easyop::Flow` class discovered at runtime; shows execution mode (1/2/3), subject, and step count |
| **Live DAG Visualization** | Mermaid flowchart generated server-side from the live flow composition on every request; no build step |
| **Flow Runs** | Browse durable `EasyFlowRun` records; inspect step timeline, context snapshot; trigger reattempt / cancel |

### Installation

```ruby
# Gemfile
gem 'easyop-ui'
```

```ruby
# config/routes.rb
mount Easyop::UI::Engine, at: '/easyop'
```

### Configuration

```ruby
# config/initializers/easyop_ui.rb
Easyop::UI.configure do |c|
  c.enable_operation_logs = true
  c.enable_flow_index     = true
  c.enable_dag_viewer     = true
  c.enable_flow_runs      = true   # requires easyop/persistent_flow

  c.authenticate_with { |request| request.env['warden'].user&.admin? }

  c.title    = 'My App — Easyop Dashboard'
  c.per_page = 50
end
```

---

## DAG Rake Tasks

The core `easyop` gem ships rake tasks for generating DAG diagrams from the CLI, without requiring `easyop-ui`.

```bash
# Export all flow DAGs as HTML → tmp/easyop_dags/index.html
rake easyop:dag:generate

# Single flow only
rake easyop:dag:generate FLOW=FulfillOrder

# Custom output directory
rake easyop:dag:generate OUTPUT=public/dags

# Print Mermaid definition to stdout (pipe to file, mermaid-cli, etc.)
rake easyop:dag:print[FulfillOrder]

# List all discovered Easyop::Flow classes with mode and step count
rake easyop:dag:list
```

The generated HTML is a self-contained file using [Mermaid.js](https://mermaid.js.org/) from CDN — open it in any browser. No Mermaid CLI, no build tools.

**Guard lambda nodes** (bare `Proc` entries in `flow`) are rendered as diamond decision nodes. **Embedded sub-flows** appear as labeled subgraphs with their own internal nodes.

---

## AI Tools — Claude Skill & LLM Context

EasyOp ships with two sets of AI helpers so any LLM can write idiomatic operations without you re-explaining the API.

### Claude Code Skill

Copy the plugin into your project and Claude will auto-activate whenever you mention operations, flows, or `easyop`:

```bash
# From your project root
cp -r path/to/easyop/claude-plugin/.claude-plugin .
cp -r path/to/easyop/claude-plugin/skills .
```

Or reference it from your existing `CLAUDE.md`:

```markdown
## EasyOp
@path/to/easyop/claude-plugin/skills/easyop/SKILL.md
```

Once installed, Claude generates correct boilerplate for operations, flows, rollback, plugins, and RSpec tests — no copy-pasting the README.

### LLM Context Files (`llms/`)

| File | When to use |
|---|---|
| `llms/overview.md` | Before asking an AI to **modify or extend the gem** — covers the full file map and plugin architecture |
| `llms/usage.md` | Before asking an AI to **write application code** — covers all patterns: basic ops, flows, plugins, Rails integration, testing |

Paste either file as a system message in Claude.ai / ChatGPT / Gemini, or use Cursor's "Add to context" feature before asking your question.

See the **[AI Tools docs page](https://pniemczyk.github.io/easyop/ai-tools.html)** for full details including programmatic usage with the Anthropic API.

---

## Module Reference

### Core

| Class/Module | Description |
|---|---|
| `Easyop::Operation` | Core mixin — include in any class to make it an operation |
| `Easyop::Flow` | Includes `Operation`; adds `flow` DSL and sequential execution |
| `Easyop::FlowBuilder` | Builder returned by `FlowClass.prepare` |
| `Easyop::Ctx` | The shared context/result object |
| `Easyop::Ctx::Failure` | Raised by `ctx.fail!`; rescued by `.call`, propagated by `.call!` |
| `Easyop::Hooks` | `before`/`after`/`around` hook system (no ActiveSupport) |
| `Easyop::Rescuable` | `rescue_from` DSL |
| `Easyop::Skip` | `skip_if` DSL for conditional step execution in flows |
| `Easyop::Schema` | `params`/`result` typed schema DSL |
| `Easyop::SimpleCrypt` | `ActiveSupport::MessageEncryptor` wrapper; `encrypt`, `decrypt`, `encrypt_marker`, `decrypt_marker` |

### Plugins (opt-in)

| Class/Module | Require | Description |
|---|---|---|
| `Easyop::Plugins::Base` | `easyop/plugins/base` | Abstract base — inherit to build custom plugins |
| `Easyop::Plugins::Instrumentation` | `easyop/plugins/instrumentation` | Emits `"easyop.operation.call"` via `ActiveSupport::Notifications` |
| `Easyop::Plugins::Recording` | `easyop/plugins/recording` | Persists every execution to an ActiveRecord model |
| `Easyop::Plugins::Async` | `easyop/plugins/async` | Enqueue operations as background jobs via ActiveJob; `call_async`, `queue` DSL |
| `Easyop::Plugins::Async::Job` | (created lazily) | The ActiveJob class that deserializes and runs the operation |
| `Easyop::Plugins::Transactional` | `easyop/plugins/transactional` | Wraps operation in an AR/Sequel transaction; `transactional false` to opt out |
| `Easyop::Plugins::Events` | `easyop/plugins/events` | Emits domain events after execution; `emits` DSL with `on:`, `payload:`, `guard:` |
| `Easyop::Plugins::EventHandlers` | `easyop/plugins/event_handlers` | Subscribes an operation to handle domain events; `on` DSL with glob patterns |

### Testing (`require 'easyop/testing'`)

| Class/Module | Description |
|---|---|
| `Easyop::Testing` | Top-level include — pulls in all assertion modules automatically |
| `Easyop::Testing::Assertions` | `op_call`, `op_call!`, `stub_op`, `assert_op_success`, `assert_op_failure`, `assert_ctx_has` |
| `Easyop::Testing::FakeModel` | In-memory AR-compatible spy for the Recording plugin |
| `Easyop::Testing::RecordingAssertions` | `assert_params_recorded`, `assert_params_filtered`, `assert_params_encrypted`, `decrypt_recorded_param`, … |
| `Easyop::Testing::AsyncAssertions` | `capture_async`, `perform_async_inline`, `assert_async_enqueued`, `assert_async_wait`, … |
| `Easyop::Testing::EventAssertions` | `capture_events`, `assert_event_emitted`, `assert_event_payload`, `assert_event_source`, … |

### Domain Events Infrastructure

| Class/Module | Require | Description |
|---|---|---|
| `Easyop::Events::Event` | `easyop/events/event` | Immutable frozen value object: `name`, `payload`, `metadata`, `timestamp`, `source` |
| `Easyop::Events::Bus::Base` | `easyop/events/bus` | Abstract adapter interface (`publish`, `subscribe`, `unsubscribe`) and glob helpers |
| `Easyop::Events::Bus::Adapter` | `easyop/events/bus/adapter` | **Inheritable base for custom buses.** Adds `_safe_invoke` + `_compile_pattern` (memoized). Subclass this. |
| `Easyop::Events::Bus::Memory` | `easyop/events/bus/memory` | In-process synchronous bus (default). Thread-safe. |
| `Easyop::Events::Bus::ActiveSupportNotifications` | `easyop/events/bus/active_support_notifications` | `ActiveSupport::Notifications` adapter |
| `Easyop::Events::Bus::Custom` | `easyop/events/bus/custom` | Wraps any user-provided bus object (duck-typed, no subclassing needed) |
| `Easyop::Events::Registry` | `easyop/events/registry` | Global bus holder + handler subscription registry |

---

## Releasing a New Version

Follow these steps to bump the version, update the changelog, and publish a tagged release.

### 1. Bump the version number

Edit `lib/easyop/version.rb` and increment the version string following [Semantic Versioning](https://semver.org/):

```ruby
# lib/easyop/version.rb
module Easyop
  VERSION = "0.1.5"   # was 0.1.4
end
```

### 2. Update the changelog

In `CHANGELOG.md`, move everything under `[Unreleased]` into a new versioned section:

```markdown
## [Unreleased]

## [0.1.5] — YYYY-MM-DD   # ← new section

### Added
- …

## [0.1.4] — 2026-04-14
```

Add a comparison link at the bottom of the file:

```markdown
[Unreleased]: https://github.com/pniemczyk/easyop/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/pniemczyk/easyop/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/pniemczyk/easyop/compare/v0.1.3...v0.1.4
```

### 3. Commit the release changes

```bash
git add lib/easyop/version.rb CHANGELOG.md
git commit -m "Release v0.1.5"
```

### 4. Tag the commit

```bash
git tag -a v0.1.5 -m "Release v0.1.5"
```

### 5. Push the commit and tag

```bash
git push origin master
git push origin v0.1.5
```

### 6. Build and push the gem (optional)

```bash
gem build easyop.gemspec
gem push easyop-0.1.5.gem
```
