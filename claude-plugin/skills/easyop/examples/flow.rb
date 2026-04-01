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
