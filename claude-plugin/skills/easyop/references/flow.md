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

| | `skip_if` (on class) | Lambda guard (in flow) |
|---|---|---|
| Location | On the operation | In the flow list |
| Reuse | Automatic — always applies in any flow | Manual — redeclare in each flow |
| Readability | Flow reads as a plain list | Flow shows the condition inline |
| Best for | When the condition is intrinsic to the step | One-off, flow-specific conditions |

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

## Flow vs. Direct Call

```ruby
# Calls flow, no pre-registered callbacks:
result = ProcessCheckout.call(attrs)
result.on_success { |ctx| ... }  # post-call callback on ctx

# Calls flow with pre-registered callbacks:
ProcessCheckout.prepare
  .on_success { |ctx| ... }
  .call(attrs)
```

Both return ctx. The FlowBuilder fires its callbacks synchronously inside `.call`.
