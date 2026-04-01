# EasyOp — Operation DSL Reference

## Inclusion

```ruby
class MyOperation
  include Easyop::Operation
end
```

Including `Easyop::Operation` adds:
- `ClassMethods`: `.call`, `.call!`
- `Easyop::Hooks`: `before`, `after`, `around`, `prepare`
- `Easyop::Rescuable`: `rescue_from`
- `Easyop::Skip`: `skip_if`
- `Easyop::Schema`: `params` / `inputs`, `result` / `outputs`

## Class Methods

```ruby
MyOperation.call(attrs = {})
# Returns ctx. Swallows Ctx::Failure — caller checks ctx.failure?.
# Unhandled exceptions (not matched by rescue_from) still propagate.

MyOperation.call!(attrs = {})
# Returns ctx on success. Raises Easyop::Ctx::Failure on ctx.fail!.
```

## Instance Methods (override in subclasses)

```ruby
def call
  # Your business logic here.
  # Read ctx.some_input; write ctx.some_output = value.
  # Call ctx.fail! to stop execution.
end

def rollback
  # Called by Flow on failure (after a successful call).
  # Undo side effects: delete records, issue refunds, etc.
  # Errors here are swallowed — all registered rollbacks run.
end
```

## Hooks

```ruby
before :method_name           # run before call
before { ctx.email = ctx.email.strip }  # inline block

after  :method_name           # run after call (always, in ensure)
after  { log_result }

around :method_name           # wraps before+call+after
around { |inner| track_time { inner.call } }
```

- `before` hooks run in declaration order.
- `after` hooks run in declaration order (in `ensure` — always execute).
- `around` hooks wrap everything: `outer_around → inner_around → before → call → after`.
- Hooks are inherited by subclasses. Subclass hooks run after parent hooks.

### Around hook pattern

When using a **method name**:

```ruby
around :with_logging

def with_logging
  Rails.logger.info "start"
  yield       # continues the chain
  Rails.logger.info ctx.success? ? "ok" : ctx.error
end
```

When using a **block**:

```ruby
around { |inner| Sentry.with_scope { inner.call } }
```

The block receives the next link in the chain as a callable argument.

## rescue_from

```ruby
rescue_from ExceptionClass do |e|
  ctx.fail!(error: e.message)
end

rescue_from ExceptionClass, with: :method_name

rescue_from ErrorA, ErrorB do |e|   # multiple classes, single handler
  ctx.fail!(error: "A or B: #{e.message}")
end
```

- Handlers are checked in **child-before-parent** order, then in definition order within a class.
- The handler runs inside the operation instance (has access to `ctx`).
- Calling `ctx.fail!` inside a handler is normal — `Ctx::Failure` is swallowed.

## skip_if (Flow concern)

```ruby
skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }
```

`skip_if` is checked by `Easyop::Flow` before instantiating the step.
It has **no effect** when calling the operation directly via `.call`.

## Typed Schema (optional)

### Input validation (`params` / `inputs`)

```ruby
params do
  required :email,    String
  required :age,      Integer
  optional :plan,     String,   default: "free"
  optional :admin,    :boolean, default: false
  optional :note,     String                    # optional with no default
end
```

Validation runs as a `before` hook (prepended to run first).

### Output validation (`result` / `outputs`)

```ruby
result do
  required :user,  User
  optional :token, String
end
```

Validation runs as an `after` hook (only when `ctx.success?`).

### Type shorthands

| Symbol | Resolves to |
|--------|------------|
| `:boolean` | `TrueClass \| FalseClass` |
| `:string` | `String` |
| `:integer` | `Integer` |
| `:float` | `Float` |
| `:symbol` | `Symbol` |
| `:any` | any value (no type check) |

### Strictness

```ruby
Easyop.configure { |c| c.strict_types = true }
# true  → ctx.fail! on type mismatch
# false → warn to $stderr (default)
```

## Inheritance

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
    # StandardError is caught by ApplicationOperation's handler
  end
end
```

Subclasses inherit all hooks and rescue handlers from parent classes.
Child class rescue handlers take priority over parent handlers.

## Plugin DSL

```ruby
class ApplicationOperation
  include Easyop::Operation

  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording,    model: OperationLog
  plugin Easyop::Plugins::Async,        queue: "operations"
  plugin Easyop::Plugins::Transactional
end
```

Each `plugin` call:
1. Calls `PluginModule.install(self, **options)` — the plugin prepends/extends the class.
2. Registers the plugin in `_registered_plugins`.

Subclasses inherit all installed plugins from their parent.

## `_registered_plugins`

Inspect which plugins have been activated on a class:

```ruby
ApplicationOperation._registered_plugins
# => [
#      { plugin: Easyop::Plugins::Instrumentation, options: {} },
#      { plugin: Easyop::Plugins::Recording, options: { model: OperationLog } },
#      { plugin: Easyop::Plugins::Async, options: { queue: "operations" } },
#      { plugin: Easyop::Plugins::Transactional, options: {} }
#    ]
```

`_registered_plugins` returns only the plugins registered directly on that class — not those from ancestor classes.
