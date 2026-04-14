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
      events.rb                # Easyop::Plugins::Events — domain event producer (emits DSL)
      event_handlers.rb        # Easyop::Plugins::EventHandlers — domain event subscriber (on DSL)
    events/
      event.rb                 # Easyop::Events::Event — immutable frozen value object
      bus.rb                   # Easyop::Events::Bus::Base — adapter interface
      bus/
        memory.rb              # Easyop::Events::Bus::Memory — in-process default
        active_support_notifications.rb  # Easyop::Events::Bus::ActiveSupportNotifications
        custom.rb              # Easyop::Events::Bus::Custom — wraps user adapter
        adapter.rb             # Easyop::Events::Bus::Adapter — inheritable base for custom buses
      registry.rb              # Easyop::Events::Registry — global bus + subscriptions
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

**Recording plugin integration**: `CallBehavior#call` automatically sets `__recording_parent_operation_name` and `__recording_parent_reference_id` in ctx before running steps, so every step log entry links back to the flow. This works with bare `include Easyop::Flow` (flow not recorded, steps carry correct parent) AND when the flow inherits from a recorded base class (flow appears in logs as root, RunWrapper handles ctx):

```ruby
# Recommended — flow recorded as tree root, steps as children:
class ProcessOrder < ApplicationOperation
  include Easyop::Flow
  transactional false   # steps manage their own transactions
  flow ValidateCart, ChargePayment, CreateOrder
end
```

Forwarding is skipped when `_recording_enabled?` is present on the flow class (i.e. Recording is installed) — RunWrapper already handles it, avoiding double-setup.

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

**Optional flow-tracing columns** (add to get full call-tree visibility):

| Column | Type | Description |
|--------|------|-------------|
| `root_reference_id` | `string` | Shared UUID across all operations in one execution tree |
| `reference_id` | `string` | Unique UUID for this specific operation execution |
| `parent_operation_name` | `string` | Class name of the direct parent operation |
| `parent_reference_id` | `string` | `reference_id` of the direct parent |

These columns are populated automatically when present in the model table (backward-compatible — missing columns are silently skipped). The plugin uses `__recording_root_reference_id`, `__recording_parent_operation_name`, and `__recording_parent_reference_id` as internal ctx keys (double-underscore prefix) to propagate tracing state through nested calls; these keys are excluded from `params_data`.

**`record_result` DSL** — selectively persist ctx output data into an optional `result_data :text` column (stored as JSON). Three forms:

```ruby
record_result attrs: :invoice_id                          # one or more ctx keys
record_result attrs: [:invoice_id, :total]
record_result { |ctx| { total: ctx.total } }              # block
record_result :build_result                               # private instance method
```

Plugin-level default (inherited by subclasses): `plugin ..., record_result: { attrs: :metadata }`.
Class-level `record_result` overrides the plugin default. Missing ctx keys → `nil`. AR objects → `{ id:, class: }`. Serialization errors swallowed. Column silently skipped when absent (backward-compatible).

### Async

Adds `.call_async(attrs, wait:, wait_until:, queue:)`.
Serializes AR objects as `{ "__ar_class", "__ar_id" }` and re-fetches in the job.
Default queue set via `plugin Easyop::Plugins::Async, queue: "myqueue"` or via the `queue` class method DSL:

```ruby
class Weather::BaseOperation < ApplicationOperation
  queue :weather   # overrides the plugin-level default; inherited by subclasses
end

class Weather::CleanupExpiredDays < Weather::BaseOperation
  queue :low_priority   # override at leaf class level
end
```

`queue` accepts `Symbol` or `String`. Per-call `queue:` argument to `.call_async` always wins.

### Transactional

Wraps `prepare { call }` in an AR/Sequel transaction.
Opt out: `transactional false`.
Works with `include` style and `plugin` DSL.

### Events (producer plugin)

Emits domain events after `_easyop_run` completes (in an `ensure` block).
Bus adapter is configurable. Declarations are inherited by subclasses.

```ruby
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"

class PlaceOrder < ApplicationOperation
  plugin Easyop::Plugins::Events

  emits "order.placed", on: :success, payload: [:order_id, :total]
  emits "order.failed", on: :failure, payload: ->(ctx) { { error: ctx.error } }
  emits "order.attempted", on: :always, guard: ->(ctx) { ctx.user_id? }
end
```

`emits` options: `on:` (`:success`/`:failure`/`:always`), `payload:` (Proc/Array/nil), `guard:` (Proc).

### EventHandlers (subscriber plugin)

Registers an operation as a handler for domain events. Registration happens at class-load time.

```ruby
require "easyop/plugins/event_handlers"

class SendConfirmation < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers
  on "order.placed"

  def call
    OrderMailer.confirm(ctx.order_id).deliver_later
  end
end
```

Glob patterns: `"order.*"` (one segment), `"warehouse.**"` (any depth).
Async: `on "order.*", async: true, queue: "low"` — requires `Plugins::Async` also installed.
Handler receives `ctx.event` (Event object, sync) or `ctx.event_data` (Hash, async) + payload keys.

### Events Registry and Bus

```ruby
# Configure globally before handler classes load:
Easyop::Events::Registry.bus = :memory           # default (in-process, sync)
Easyop::Events::Registry.bus = :active_support   # ActiveSupport::Notifications
Easyop::Events::Registry.bus = MyRabbitBus.new   # custom adapter

# Or via config:
Easyop.configure { |c| c.event_bus = :active_support }

# Reset in tests:
Easyop::Events::Registry.reset!
```

`Bus::Memory` is thread-safe (Mutex).

**Custom bus adapters** — two options:

| Approach | When to use |
|---|---|
| Subclass `Bus::Adapter` | Building a new transport (RabbitMQ, Redis, Kafka, …). Inherits `_safe_invoke` + `_compile_pattern`. |
| Pass a duck-typed object | Wrapping an existing object that already responds to `#publish`/`#subscribe`. Registry auto-wraps it in `Bus::Custom`. |

`Bus::Adapter` protected helpers:

| Method | Description |
|---|---|
| `_safe_invoke(handler, event)` | Calls `handler.call(event)`, rescues `StandardError`. Prevents one broken handler from blocking others. |
| `_compile_pattern(pattern)` | Converts a glob/string to a `Regexp`, memoized per unique pattern string in the bus instance. |

`Bus::Base` private helpers (inherited by both `Bus::Adapter` and the built-in adapters):

| Method | Description |
|---|---|
| `_pattern_matches?(pattern, name)` | Returns true when `pattern` (String glob or Regexp) matches `name`. |
| `_glob_to_regex(glob)` | Converts `"order.*"` → `/\Aorder\.[^.]+\z/`, `"warehouse.**"` → `/\Awarehouse\..+\z/`. |

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

### Events fire in ensure — never crash the operation

The Events plugin's `RunWrapper` wraps `_easyop_run` with an `ensure` block.
Events are published after `super` returns (or raises). Individual publish failures
are rescued per-declaration — one broken handler never blocks others.

The `if:` keyword cannot be used as a Ruby method keyword argument without workarounds;
use `guard:` instead for the optional condition Proc.

### EventHandlers register at class-load time

`on` calls `Easyop::Events::Registry.register_handler` immediately when the class body
is evaluated. The bus active at that moment receives the subscription. Swapping the bus
after handler classes load does not re-register existing subscriptions.

### Rollback stores instances, not classes

`ctx.called!(instance)` — the instance already has `@ctx` set via `_easyop_run`,
so its `rollback` method has full ctx access.
