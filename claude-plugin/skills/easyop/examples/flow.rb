# frozen_string_literal: true

# EasyOp — Flow Composition Examples

# ── 1. Basic flow ─────────────────────────────────────────────────────────────

class ValidateCart
  include Easyop::Operation

  def call
    ctx.fail!(error: "Cart is empty") if ctx.cart.items.empty?
    ctx.total = ctx.cart.items.sum(&:price)
  end
end

class ApplyCoupon
  include Easyop::Operation

  # Skipped automatically by the Flow when no coupon_code is present
  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    coupon = Coupon.find_by(code: ctx.coupon_code)
    ctx.fail!(error: "Invalid or expired coupon") unless coupon&.active?
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

  # Called in reverse order when a later step fails
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
    ctx.order.destroy! if ctx.order&.persisted?
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
       ApplyCoupon,       # skipped when ctx.coupon_code is absent/empty
       ChargePayment,
       CreateOrder,
       SendConfirmation
end

# ── 2. Direct call ────────────────────────────────────────────────────────────

result = ProcessCheckout.call(
  user:          current_user,
  cart:          current_cart,
  payment_token: params[:stripe_token],
  coupon_code:   params[:coupon_code]   # optional
)

result.success?   # => true
result.order      # => #<Order ...>
result.discount   # => 10 if coupon applied, nil if skipped

# ── 3. Post-call callbacks on ctx ────────────────────────────────────────────

ProcessCheckout.call(user: current_user, cart: current_cart)
  .on_success { |ctx| puts "Order #{ctx.order.id} placed" }
  .on_failure { |ctx| puts "Checkout failed: #{ctx.error}" }

# ── 4. FlowBuilder — prepare ──────────────────────────────────────────────

ProcessCheckout.prepare
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| flash[:error] = ctx.error; redirect_back }
  .call(
    user:          current_user,
    cart:          current_cart,
    payment_token: params[:stripe_token],
    coupon_code:   params[:coupon_code]
  )

# ── 5. FlowBuilder — bind_with + on ──────────────────────────────────────────

ProcessCheckout.prepare
  .bind_with(self)             # bind a controller or other host object
  .on(success: :order_placed, fail: :checkout_failed)
  .call(
    user:          current_user,
    cart:          current_cart,
    payment_token: params[:stripe_token],
    coupon_code:   params[:coupon_code]
  )

# ── 6. Lambda guard (inline alternative to skip_if) ──────────────────────────

class ProcessCheckoutWithGuard
  include Easyop::Flow

  flow ValidateCart,
       ->(ctx) { ctx.coupon_code? }, ApplyCoupon,   # explicit inline guard
       ChargePayment,
       CreateOrder
end

# ── 7. Nested flows ───────────────────────────────────────────────────────────

class AuthAndValidate
  include Easyop::Flow
  flow AuthenticateUser, ValidatePermissions
end

class FullCheckout
  include Easyop::Flow
  flow AuthAndValidate, ValidateCart, ChargePayment, CreateOrder
end

# ctx is shared across all nesting levels

# ── 8. Flow with multiple callbacks ──────────────────────────────────────────

ProcessCheckout.prepare
  .on_success { |ctx| Analytics.track("checkout_complete", order_id: ctx.order.id) }
  .on_success { |ctx| redirect_to order_path(ctx.order), notice: "Order placed!" }
  .on_failure { |ctx| Rails.logger.warn "Checkout failed: #{ctx.error}" }
  .on_failure { |ctx| render json: { error: ctx.error }, status: 422 }
  .call(user: current_user, cart: current_cart)

# ── 9. Mode-2 fire-and-forget async (no subject, has .async step) ─────────────
#
# SendWelcomeEmail MUST have plugin Easyop::Plugins::Async installed.
# The flow returns Ctx immediately; SendWelcomeEmail is enqueued via call_async.
# No database or Scheduler dependency required.

class RegisterAndNotify
  include Easyop::Flow

  flow CreateUser,
       SendWelcomeEmail.async,   # fire-and-forget via ActiveJob
       AssignTrial               # sync — runs right after enqueue
end

ctx = RegisterAndNotify.call(email: 'alice@example.com', name: 'Alice')
ctx.success?   # => true (even though SendWelcomeEmail has not run yet)
ctx.user       # => the newly created User record

# ── 10. Mode-3 durable flow (subject, returns FlowRun) ───────────────────────
#
# Requires in initializer:
#   require 'easyop/scheduler'
#   require 'easyop/persistent_flow'
#
# And the generated AR models from: bin/rails generate easyop:install
#
# SendWelcomeEmail and SendNudge MUST have plugin Easyop::Plugins::Async installed.

class OnboardSubscriber
  include Easyop::Flow

  subject :user   # ← the ONLY durability trigger; binds a polymorphic AR ref

  flow CreateAccount,
       SendWelcomeEmail.async,                    # deferred via DB Scheduler
       SendNudge.async(wait: 3.days)
                .skip_if { |ctx| ctx[:skip_nudge] },
       RecordComplete
end

flow_run = OnboardSubscriber.call(user: user, plan: :pro)
flow_run.status   # => 'running' (waiting for async step)
flow_run.subject  # => the User AR record
flow_run.cancel!  # stop execution

# Testing durable flows — use speedrun_flow to advance async steps immediately:
#
#   include Easyop::Testing
#
#   def test_onboarding_succeeds
#     run = OnboardSubscriber.call(user: user, plan: :pro)
#     speedrun_flow(run)
#     assert_flow_status    run, :succeeded
#     assert_step_completed run, SendWelcomeEmail
#     assert_step_completed run, SendNudge
#   end

# ── 11. Free composition — outer Mode-1 + inner Mode-3 → outer returns FlowRun ─

class InnerDurable
  include Easyop::Flow
  subject :user
  flow StepA, StepB.async(wait: 1.day)
end

class OuterPlain
  include Easyop::Flow
  # No own subject, but InnerDurable has one → auto-promotes to Mode 3
  flow Op1, InnerDurable, Op2
end

run = OuterPlain.call(user: user)   # => FlowRun (not Ctx)
# InnerDurable's steps are flattened into OuterPlain._resolved_flow_steps:
#   [Op1, StepA, StepB.async(wait: 1.day), Op2]
