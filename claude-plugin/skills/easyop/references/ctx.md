# EasyOp — Ctx API Reference

`Easyop::Ctx` is the shared data bag passed through every operation. It is both
the input carrier and the result object returned from `.call`.

## Construction

```ruby
Easyop::Ctx.build(hash)   # wraps a Hash; returns an existing Ctx unchanged
Easyop::Ctx.new(hash)     # always creates a new Ctx
```

## Reading Attributes

```ruby
ctx[:email]       # hash-style — returns nil for missing keys
ctx.email         # method-style via method_missing — returns nil for missing keys
ctx.admin?        # predicate: !!ctx[:admin] — false for missing keys, never raises
ctx.key?(:email)  # explicit existence check
ctx.to_h          # returns a plain Hash copy of all attributes
```

## Writing Attributes

```ruby
ctx[:email] = "alice@example.com"   # hash-style
ctx.email   = "alice@example.com"   # method-style
ctx.merge!(email: "alice@example.com", name: "Alice")  # bulk-set
```

## Extracting a Subset

```ruby
ctx.slice(:name, :email, :plan)
# => { name: "Alice", email: "alice@example.com", plan: "free" }
# Keys not present in ctx are silently omitted.
```

## Status

```ruby
ctx.success?   # true unless ctx.fail! was called — alias: ctx.ok?
ctx.failure?   # true after ctx.fail! — aliases: ctx.failed?
```

## Failing

```ruby
ctx.fail!
# Marks ctx as failed and raises Easyop::Ctx::Failure (swallowed by .call).

ctx.fail!(error: "Something went wrong")
# Merges the hash into ctx, then marks failed and raises.

ctx.fail!(error: "Validation failed", errors: { email: "is blank", name: "is required" })
# Structured failure with field-level errors.
```

`ctx.fail!` always raises `Easyop::Ctx::Failure`. In `.call` this is swallowed
(caller checks `ctx.failure?`). In `.call!` it propagates.

## Error Convenience Methods

```ruby
ctx.error          # shortcut for ctx[:error]
ctx.error = "msg"  # shortcut for ctx[:error] = "msg"
ctx.errors         # shortcut for ctx[:errors] — returns {} if not set
ctx.errors = {}    # shortcut for ctx[:errors] = {}
```

## Post-call Chainable Callbacks

```ruby
AuthenticateUser.call(email: email, password: password)
  .on_success { |ctx| sign_in(ctx.user) }
  .on_failure { |ctx| flash[:alert] = ctx.error }
```

Both methods yield `self` (the ctx) to the block if the condition matches,
then return `self` — making them chainable. Neither raises.

## Rollback Support

```ruby
ctx.called!(instance)  # register an instance for rollback (called by Flow)
ctx.rollback!          # call .rollback on registered instances in reverse order;
                       # errors inside rollback are swallowed; idempotent
```

## Pattern Matching (Ruby 3+)

```ruby
ctx.deconstruct_keys(keys)
# Returns: { success: bool, failure: bool, **all_attributes }
# If keys is non-nil, the hash is sliced to only those keys.

case result
in { success: true, user: User => user }  then sign_in(user)
in { success: false, error: String => e } then flash[:alert] = e
end
```

## Inspect

```ruby
ctx.inspect
# => "#<Easyop::Ctx {name: \"Alice\", email: \"alice@example.com\"} [ok]>"
# => "#<Easyop::Ctx {error: \"Invalid\"} [FAILED]>"
```

## `Easyop::Ctx::Failure`

Raised internally by `ctx.fail!`. Carries the ctx that failed.

```ruby
rescue Easyop::Ctx::Failure => e
  e.ctx          # => the Ctx instance
  e.ctx.error    # => the error message
  e.message      # => "Operation failed: <error>" or "Operation failed"
end
```
