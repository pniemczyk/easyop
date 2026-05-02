# EasyOp — Flow + FlowBuilder Reference

## Basic Flow

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
result.success?   # => true
result.order      # => #<Order ...>
```

`include Easyop::Flow` also includes `Easyop::Operation`, giving the flow class
access to `call`, `call!`, hooks, `rescue_from`, etc.

## How a Flow Executes

1. `ProcessCheckout.call(attrs)` creates a single `ctx` from `attrs`.
2. Each step in the `flow` list is checked for `skip_if` — skipped steps are not run and not registered for rollback.
3. For each non-skipped step: `instance = step.new; instance._easyop_run(ctx, raise_on_failure: true)`.
4. The step's `call` runs inside its own `prepare` chain. The same `ctx` is used across all steps.
5. On success, the instance is added to `ctx.called!` (for potential rollback).
6. If any step calls `ctx.fail!`, the `Ctx::Failure` propagates up through the flow, triggering `ctx.rollback!`.
7. `ctx` is returned to the caller.

## Rollback

Define a `rollback` method on any step to undo its side effects on failure:

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

**Rollback rules:**
- Runs only on already-completed steps (the failing step itself is not rolled back).
- Runs in reverse completion order.
- Errors inside `rollback` are swallowed — all registered rollbacks run regardless.
- Skipped steps are never added to the rollback list.

## skip_if — Class-level Step Condition

Declare the skip condition on the operation itself:

```ruby
class ApplyCoupon
  include Easyop::Operation

  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    ctx.discount = CouponService.apply(ctx.coupon_code)
  end
end
```

In the flow declaration, just list the step — the skip logic is encapsulated:

```ruby
flow ValidateCart, ApplyCoupon, ChargePayment, CreateOrder
```

## Lambda Guards — Inline Condition

Place a lambda immediately before a step to gate it:

```ruby
flow ValidateCart,
     ->(ctx) { ctx.coupon_code? }, ApplyCoupon,   # only if coupon present
     ChargePayment,
     CreateOrder
```

The lambda receives `ctx` and the step runs only if it returns truthy.

## Choosing Between skip_if and Lambda Guards

| | `skip_if` on class | Lambda guard (in flow) |
|---|---|---|
| Location | On the operation | In the flow list |
| Reuse | Automatic in any flow | Manual |
| Readability | Flow is a plain list | Shows condition inline |
| Best for | Intrinsic step condition | One-off flow condition |

## Nested Flows

A Flow class can be used as a step inside another Flow:

```ruby
class AuthAndValidate
  include Easyop::Flow
  flow AuthenticateUser, ValidatePermissions
end

class ProcessOrder
  include Easyop::Flow
  flow AuthAndValidate, ValidateCart, ChargePayment, CreateOrder
end
```

`ctx` is shared across all nesting levels. Rollback propagates correctly.

## `prepare` — FlowBuilder

`FlowClass.prepare` returns an `Easyop::FlowBuilder`. **Do not call `flow` with
no args** — `flow` is only for declaring steps.

### Block callbacks

```ruby
ProcessCheckout.prepare
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| flash[:error] = ctx.error; redirect_back }
  .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])
```

### Multiple callbacks (run in registration order)

```ruby
ProcessCheckout.prepare
  .on_success { |ctx| Analytics.track("checkout", order: ctx.order) }
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| Rails.logger.error "Failed: #{ctx.error}" }
  .on_failure { |ctx| render json: { error: ctx.error }, status: 422 }
  .call(attrs)
```

### Symbol callbacks with bind_with (Rails controller pattern)

```ruby
ProcessCheckout.prepare
  .bind_with(self)
  .on(success: :order_placed, fail: :checkout_failed)
  .call(user: current_user, cart: current_cart)
```

The bound object's method is called with `ctx` as argument (or without, if the
method is zero-arity):

```ruby
def order_placed(ctx)         # receives ctx
  redirect_to order_path(ctx.order)
end

def order_placed              # zero-arity — ctx not passed
  redirect_to orders_path
end
```

### FlowBuilder returns ctx

```ruby
ctx = ProcessCheckout.prepare
        .on_success { |ctx| ... }
        .call(attrs)

ctx.success?  # check after-the-fact if needed
```

Note: `prepare` is only supported for Mode-1 and Mode-2 (non-durable) flows.
Calling `prepare` on a durable flow (one with `subject` declared) raises `ArgumentError`.

## Flow vs. Direct Call

```ruby
# Calls flow, no pre-registered callbacks:
result = ProcessCheckout.call(attrs)
result.on_success { |ctx| ... }  # post-call callback on ctx

# Calls flow with pre-registered callbacks (Mode 1 / Mode 2 only):
ProcessCheckout.prepare
  .on_success { |ctx| ... }
  .call(attrs)
```

Mode 1 and Mode 2 flows return `Ctx`; Mode 3 (durable) flows return `FlowRun`.

## Three Execution Modes

`Easyop::Flow` auto-selects the execution mode:

| Mode | Declaration | Returns |
|------|-------------|---------|
| 1 — sync | No `subject`, no `.async` step | `Ctx` |
| 2 — fire-and-forget async | No `subject`, has `.async` step | `Ctx` (async steps enqueued via `call_async`) |
| 3 — durable | `subject` declared | `FlowRun` (DB-backed) |

`subject` is the **only** durability trigger. `.async` steps alone do NOT make a flow durable.

## Durability mode (`subject`)

```ruby
require 'easyop/scheduler'
require 'easyop/persistent_flow'

class OnboardSubscriber
  include Easyop::Flow

  subject :user   # ← the only durability trigger

  flow CreateAccount,
       SendWelcomeEmail.async,                     # deferred via DB scheduler
       SendNudge.async(wait: 3.days)
                .skip_if { |ctx| ctx[:skip_nudge] },
       RecordComplete
end

flow_run = OnboardSubscriber.call(user: user, plan: :pro)
# => FlowRun AR record; status: 'running'

flow_run.cancel!     # stop execution
flow_run.resume!     # re-advance from last completed step
flow_run.succeeded?  # => true when all steps finished
```

## Free composition

When a non-durable outer flow embeds a durable (subject-bearing) sub-flow, the
sub-flow's steps are **flattened** into the outer's `_resolved_flow_steps`, which
auto-promotes the outer to Mode 3:

```ruby
class InnerDurable
  include Easyop::Flow
  subject :user
  flow StepA, StepB.async(wait: 1.day)
end

class Outer
  include Easyop::Flow
  flow Op1, InnerDurable, Op2   # no subject declared, but InnerDurable has one
end

run = Outer.call(user: user)    # => FlowRun (auto-promoted to Mode 3)
```

The outer flow inherits `subject` from the first durable sub-flow found
(`_resolved_subject` searches depth-first).

Mode-2 sub-flows stay encapsulated as a single inline step — they never promote
the outer to Mode 3.
