# EasyOp — Hooks and rescue_from Reference

## Hook Types

| Hook | When it runs | Returns self? |
|------|-------------|--------------|
| `before` | Before `call`, in declaration order | — |
| `after` | After `call` (in `ensure` — always), in declaration order | — |
| `around` | Wraps `before + call + after`; outermost first | must call `yield` or `inner.call` |

## Declaring Hooks

### Method name (Symbol)

```ruby
before :normalize_email
after  :send_notification
around :with_logging
```

The named method is called on the operation instance and has full access to `ctx`.

### Inline block

```ruby
before { ctx.email = ctx.email.to_s.strip.downcase }
after  { Rails.logger.info "Done: #{ctx.inspect}" }
around { |inner| track_time { inner.call } }
```

Blocks are instance-exec'd on the operation instance.

### Mixed

```ruby
before :normalize_email
before { ctx.plan ||= "free" }     # multiple befores run in order
after  :cleanup
```

## Execution Order

Given this class:

```ruby
around :outer
around :inner
before :before1
before :before2
after  :after1
after  :after2
```

Execution order:
1. `outer` begins (calls inner link)
2. `inner` begins (calls inner link)
3. `before1`
4. `before2`
5. `call`
6. `after1`
7. `after2`
8. `inner` finishes
9. `outer` finishes

## Around Hooks — Method Style

```ruby
around :with_timing

def with_timing
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield                    # continues the chain
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  Rails.logger.info "Took #{(elapsed * 1000).round(2)}ms"
end
```

`yield` inside a method-style hook works correctly (it delegates to the next
link in the around chain, not to an arbitrary block).

## Around Hooks — Block Style

```ruby
around { |inner| Sentry.with_scope { inner.call } }
around do |inner|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  inner.call
  puts "#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000}ms"
end
```

The block receives the next link as a callable (`inner`). Call `inner.call` to
continue. If you forget to call it, the rest of the chain (including `call`)
never runs — no error is raised.

## Hook Inheritance

Subclasses inherit parent hooks. The combined list is parent_hooks + own_hooks:

```ruby
class ApplicationOperation
  include Easyop::Operation
  around :with_error_tracking
end

class CreateUser < ApplicationOperation
  before :validate_email    # runs after ApplicationOperation's around wraps it
  def call; ...; end
end
```

Order for a `CreateUser` call:
1. `with_error_tracking` begins (inherited `around`)
2. `validate_email` (own `before`)
3. `call`
4. `with_error_tracking` finishes

## rescue_from

Handles exceptions raised inside `call` (and hooks) without requiring
begin/rescue in the `call` method.

```ruby
rescue_from ExceptionClass do |e|
  ctx.fail!(error: e.message)
end

rescue_from ExceptionClass, with: :handler_method_name

rescue_from ErrorA, ErrorB do |e|    # multiple classes, single handler
  ctx.fail!(error: "handled: #{e.class}")
end
```

### Handler lookup

1. Own handlers (defined on this class) are checked first.
2. Parent handlers are checked next.
3. Within each group, handlers are checked in definition order — first match wins.
4. If no handler matches, the exception is re-raised (after marking ctx failed).

```ruby
class ApplicationOperation
  include Easyop::Operation
  rescue_from StandardError, with: :catch_all
end

class MyOp < ApplicationOperation
  rescue_from ActiveRecord::RecordInvalid do |e|
    ctx.fail!(error: e.record.errors.full_messages.first)
  end
  # ActiveRecord::RecordInvalid is caught by the child handler (above)
  # Other StandardErrors are caught by ApplicationOperation's :catch_all
end
```

### Handler context

The handler block or method runs on the operation instance:

```ruby
rescue_from SomeError do |e|
  ctx.fail!(error: e.message)  # ctx is available
  log_error(e)                 # private methods are available
end
```

### Calling `ctx.fail!` inside a handler

This is the standard pattern. `Ctx::Failure` raised by `ctx.fail!` inside a
handler is automatically swallowed — the operation ends as failed.

### Unhandled exceptions

If no handler matches, the operation calls `ctx.fail!(error: e.message)` (to
mark the ctx failed) and then re-raises the original exception. The caller sees
both a failed ctx (if they rescue the exception themselves) and the exception.
