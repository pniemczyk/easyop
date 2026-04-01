# EasyOp — LLM Context Overview

> Load this file before modifying or extending the gem.

## Purpose

`easyop` wraps business logic in composable, testable operation objects. Each
operation receives a `ctx` (context) object, does its work, and either succeeds
or fails. No required runtime dependencies — works in Rails, Sinatra, or plain Ruby.

## File map

```
lib/
  easyop.rb                    # Entry point — requires all modules in dependency order
  easyop/
    version.rb                 # VERSION constant
    configuration.rb           # Easyop.configure { |c| c.strict_types = false }
    ctx.rb                     # Easyop::Ctx — shared context + result object
    hooks.rb                   # Easyop::Hooks — before/after/around hook system
    rescuable.rb               # Easyop::Rescuable — rescue_from DSL
    skip.rb                    # Easyop::Skip — skip_if DSL for conditional flow steps
    schema.rb                  # Easyop::Schema — optional typed params/result DSL
    operation.rb               # Easyop::Operation — the core mixin
    flow_builder.rb            # Easyop::FlowBuilder — callback builder returned by prepare
    flow.rb                    # Easyop::Flow — sequential operation chain
    plugins/
      base.rb                  # Easyop::Plugins::Base — abstract base for custom plugins
      instrumentation.rb       # Easyop::Plugins::Instrumentation — ActiveSupport::Notifications
      recording.rb             # Easyop::Plugins::Recording — persists executions to AR model
      async.rb                 # Easyop::Plugins::Async — .call_async via ActiveJob
      transactional.rb         # Easyop::Plugins::Transactional — DB transaction wrapper
spec/
  easyop/                      # RSpec specs, one file per module
examples/
  usage.rb                     # 13 runnable examples
llms/
  overview.md                  # This file
  usage.md                     # Common patterns and recipes
```

## Public surface

### Single operation

```ruby
class DoSomething
  include Easyop::Operation

  def call
    ctx.fail!(error: "invalid") unless ctx.input.is_a?(String)
    ctx.result = ctx.input.upcase
  end
end

result = DoSomething.call(input: "hello")
result.success?  # => true
result.result    # => "HELLO"

result = DoSomething.call(input: 42)
result.failure?  # => true
result.error     # => "invalid"
```

### Flow

```ruby
class ProcessOrder
  include Easyop::Flow

  flow ValidateCart,
       ApplyCoupon,       # skipped when skip_if predicate is truthy
       ChargePayment,
       CreateOrder
end

result = ProcessOrder.call(user: current_user, cart: cart)
```

### FlowBuilder (`prepare`)

```ruby
ProcessOrder.prepare
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| flash[:error] = ctx.error }
  .call(user: current_user, cart: cart)

ProcessOrder.prepare
  .bind_with(self)               # bind a controller or other object
  .on(success: :order_placed, fail: :show_errors)
  .call(user: current_user, cart: cart)
```

## Ctx API

| Method | Description |
|--------|-------------|
| `ctx[key]` / `ctx.key` | Read attribute |
| `ctx[key] = v` / `ctx.key = v` | Write attribute |
| `ctx.key?` | Predicate: `!!ctx[:key]` (false for missing keys, never raises) |
| `ctx.merge!(hash)` | Bulk-set attributes |
| `ctx.slice(:a, :b)` | Returns plain Hash with only those keys |
| `ctx.fail!(attrs = {})` | Merge attrs, mark failed, raise `Ctx::Failure` |
| `ctx.success?` / `ctx.ok?` | True unless `fail!` was called |
| `ctx.failure?` / `ctx.failed?` | True after `fail!` |
| `ctx.error` | Shortcut for `ctx[:error]` |
| `ctx.errors` | Shortcut for `ctx[:errors] \|\| {}` |
| `ctx.on_success { \|c\| }` | Post-call chainable callback (returns self) |
| `ctx.on_failure { \|c\| }` | Post-call chainable callback (returns self) |
| `ctx.called!(instance)` | Register an instance for rollback (called by Flow) |
| `ctx.rollback!` | Call `rollback` on registered instances in reverse; swallows errors |
| `ctx.deconstruct_keys(keys)` | Pattern matching: `{ success:, failure:, **attrs }` |

## Operation module inclusions

When `include Easyop::Operation` is evaluated, the following modules are added
to the class (in this order):

1. `ClassMethods` — `call`, `call!`
2. `Easyop::Hooks` — `before`, `after`, `around`, `prepare`
3. `Easyop::Rescuable` — `rescue_from`
4. `Easyop::Skip` — `skip_if`
5. `Easyop::Schema` — `params`/`inputs`, `result`/`outputs`

## Flow execution model

```
ProcessOrder.call(attrs)
  └── new._easyop_run(ctx, raise_on_failure: false)
        └── _run_safe
              └── prepare { call }     ← Flow::CallBehavior#call
                    ├── before hooks (none for flows by default)
                    ├── Flow#call (via CallBehavior prepend)
                    │     ├── skip_if? check per step
                    │     ├── instance = step.new
                    │     ├── instance._easyop_run(ctx, raise_on_failure: true)
                    │     └── ctx.called!(instance)
                    └── after hooks
              rescue Ctx::Failure
                └── ctx.rollback!         ← calls .rollback on instances in reverse
```

## skip_if — class-level step condition

```ruby
class ApplyCoupon
  include Easyop::Operation
  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }
  def call; ctx.discount = CouponService.apply(ctx.coupon_code); end
end
```

When Flow encounters `ApplyCoupon`, it calls `ApplyCoupon.skip?(ctx)` before
instantiating the step. If truthy, the step is skipped entirely and NOT added
to the rollback list.

Both `skip_if` and inline lambda guards work:

```ruby
# Lambda guard (inline in flow list):
flow ValidateCart, ->(ctx) { ctx.coupon_code? }, ApplyCoupon

# Class-level skip_if:
flow ValidateCart, ApplyCoupon   # ApplyCoupon declares its own skip_if
```

## Schema DSL (optional)

```ruby
class RegisterUser
  include Easyop::Operation

  params do                           # validated before call
    required :email,    String
    required :age,      Integer
    optional :plan,     String,   default: "free"
    optional :admin,    :boolean, default: false
  end

  result do                           # validated after call (in strict mode)
    required :user, User
  end
end
```

Type shorthands: `:boolean`, `:string`, `:integer`, `:float`, `:symbol`, `:any`.

Configuration: `Easyop.configure { |c| c.strict_types = true }` makes type
mismatches call `ctx.fail!` instead of `warn`.

## Plugins (opt-in)

Plugins are not required automatically. Require and activate individually:

```ruby
require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/async"
require "easyop/plugins/transactional"
```

Activate via the `plugin` DSL (all subclasses inherit):

```ruby
class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording,    model: OperationLog
  plugin Easyop::Plugins::Async,        queue: "operations"
  plugin Easyop::Plugins::Transactional
end
```

### Instrumentation

Emits `"easyop.operation.call"` via `ActiveSupport::Notifications` after every call.
Payload: `{ operation:, success:, error:, duration:, ctx: }`.
Attach built-in log subscriber: `Easyop::Plugins::Instrumentation.attach_log_subscriber`

### Recording

Persists every execution to an AR model (`model:` option required).
Required columns: `operation_name :string`, `success :boolean`, `error_message :string`, `params_data :text`, `duration_ms :float`, `performed_at :datetime`.
Scrubs `:password`, `:token`, `:secret`, `:api_key`, `:password_confirmation`.
Opt out: `recording false`.

### Async

Adds `.call_async(attrs, wait:, wait_until:, queue:)`.
Serializes AR objects as `{ "__ar_class", "__ar_id" }` and re-fetches in the job.
Default queue set via `plugin Easyop::Plugins::Async, queue: "myqueue"`.

### Transactional

Wraps `prepare { call }` in an AR/Sequel transaction.
Opt out: `transactional false`.
Works with `include` style and `plugin` DSL.

### Plugin execution order

```
plugin3::RunWrapper  (outermost — last installed)
  plugin2::RunWrapper
    plugin1::RunWrapper  (innermost)
      prepare { before → call → after }
```

### Building a custom plugin

```ruby
module MyPlugin < Easyop::Plugins::Base
  def self.install(base, **options)
    base.prepend(RunWrapper)
    base.extend(ClassMethods)
  end

  module RunWrapper
    def _easyop_run(ctx, raise_on_failure:)
      # wrap the execution
      super.tap { |ctx| do_something(ctx) }
    end
  end

  module ClassMethods
    def my_plugin(enabled); @_enabled = enabled; end
  end
end
```

## Critical design decisions

### `prepare` vs `flow` (no args)

`flow` has one job: declare steps. `prepare` returns a `FlowBuilder`.
Never call `flow` with no args expecting a builder — use `prepare`.

### `block.call` not `yield` in `prepare`

`yield` inside a `proc` does not delegate to the enclosing method's block when
the proc is invoked indirectly (via `chain.call`). `prepare` captures `&block`
and calls `block.call` inside the inner proc.

### `prepend(CallBehavior)` not `include(Flow)`

`Flow::CallBehavior` is prepended (not included) so that its `call` method
appears before `Operation#call` (a no-op) in the MRO.

### Child rescue handlers searched first

`_rescue_handlers` stores only own handlers; `_all_rescue_handlers` returns
own + parent handlers. Child class handlers always take priority.

### Rollback stores instances, not classes

`ctx.called!(instance)` — the instance already has `@ctx` set via `_easyop_run`,
so its `rollback` method has full ctx access.
