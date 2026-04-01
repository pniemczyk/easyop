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

```ruby
Easyop.configure do |c|
  c.strict_types  = false    # true = ctx.fail! on type mismatch; false = warn (default)
  c.type_adapter  = :native  # :none, :native (default), :literal, :dry, :active_model
end
```

Reset to defaults (useful in tests):

```ruby
Easyop.reset_config!
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
| `record_params:` | `true` | Set `false` to skip serializing ctx params |

**Required model columns:**

```ruby
create_table :operation_logs do |t|
  t.string   :operation_name, null: false
  t.boolean  :success,        null: false
  t.string   :error_message
  t.text     :params_data          # JSON — ctx attrs (sensitive keys scrubbed)
  t.float    :duration_ms
  t.datetime :performed_at,   null: false
end
```

The plugin automatically scrubs these keys from `params_data` before persisting: `:password`, `:password_confirmation`, `:token`, `:secret`, `:api_key`. ActiveRecord objects are serialized as `{ id:, class: }` rather than their full representation.

**Opt out per class:**

```ruby
class Newsletter::SendBroadcast < ApplicationOperation
  recording false   # skip logging for this operation
end
```

Recording failures are swallowed and logged as warnings — a failed log write never breaks the operation.

---

### Plugin: Async

Adds `.call_async` to any operation class, enqueuing execution as an ActiveJob. Requires ActiveJob (included with Rails).

```ruby
require "easyop/plugins/async"

class Newsletter::SendBroadcast < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "broadcasts"
end
```

**Enqueue immediately:**

```ruby
Newsletter::SendBroadcast.call_async(subject: "Hello", body: "World")
```

**With scheduling:**

```ruby
# Run after a delay
Newsletter::SendBroadcast.call_async(attrs, wait: 10.minutes)

# Run at a specific time
Newsletter::SendBroadcast.call_async(attrs, wait_until: Date.tomorrow.noon)

# Override the queue at call time
Newsletter::SendBroadcast.call_async(attrs, queue: "low_priority")
```

**ActiveRecord objects** are serialized by `(class, id)` and re-fetched in the job:

```ruby
# This works — Article is serialized as { "__ar_class" => "Article", "__ar_id" => 42 }
Newsletter::SendBroadcast.call_async(article: @article, subject: "Hello")
```

Only pass serializable values: `String`, `Integer`, `Float`, `Boolean`, `nil`, `Hash`, `Array`, or `ActiveRecord::Base`.

The plugin defines `Easyop::Plugins::Async::Job` lazily (on first call to `.call_async`) so you can require the plugin before ActiveJob loads.

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

```
ruby examples/usage.rb
```

## Example Rails App

A full Rails 8 blog application demonstrating every EasyOp feature in real-world code lives in `/examples/easyop_test_app/`. It is **not included in the gem** — only in the repository.

```
/examples/easyop_test_app/
```

The app covers:

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

**Running the example app:**

```bash
cd /examples/easyop_test_app
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server -p 3002
```

Seed accounts: `alice@example.com` / `password123` (500 credits), `bob`, `carol`, `dave` (0 credits — tests insufficient-funds error).

## Running Specs

```
bundle exec rspec
```

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

### Plugins (opt-in)

| Class/Module | Require | Description |
|---|---|---|
| `Easyop::Plugins::Base` | `easyop/plugins/base` | Abstract base — inherit to build custom plugins |
| `Easyop::Plugins::Instrumentation` | `easyop/plugins/instrumentation` | Emits `"easyop.operation.call"` via `ActiveSupport::Notifications` |
| `Easyop::Plugins::Recording` | `easyop/plugins/recording` | Persists every execution to an ActiveRecord model |
| `Easyop::Plugins::Async` | `easyop/plugins/async` | Adds `.call_async` via ActiveJob with AR object serialization |
| `Easyop::Plugins::Async::Job` | (created lazily) | The ActiveJob class that deserializes and runs the operation |
| `Easyop::Plugins::Transactional` | `easyop/plugins/transactional` | Wraps operation in an AR/Sequel transaction; `transactional false` to opt out |
