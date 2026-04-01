# frozen_string_literal: true

# EasyOp — Rails Controller Integration Examples

# ── Pattern 1: Post-call callbacks on ctx ─────────────────────────────────────
# Simple, works for single operations and flows alike.

class UsersController < ApplicationController
  def create
    CreateUser.call(user_params)
      .on_success { |ctx| redirect_to profile_path(ctx.user), notice: "Welcome!" }
      .on_failure { |ctx| render :new, locals: { errors: ctx.errors } }
  end

  private

  def user_params
    params.require(:user).permit(:name, :email, :password)
  end
end

# ── Pattern 2: prepare + bind_with ────────────────────────────────────────
# Best for flows in controller actions — keeps action method short.

class CheckoutsController < ApplicationController
  def create
    ProcessCheckout.prepare
      .bind_with(self)
      .on(success: :checkout_complete, fail: :checkout_failed)
      .call(
        user:          current_user,
        cart:          current_cart,
        payment_token: params[:stripe_token],
        coupon_code:   params[:coupon_code]
      )
  end

  private

  def checkout_complete(ctx)
    redirect_to order_path(ctx.order), notice: "Order ##{ctx.order.id} placed!"
  end

  def checkout_failed(ctx)
    flash.now[:error] = ctx.error
    render :new
  end
end

# ── Pattern 3: prepare block-style ────────────────────────────────────────
# Useful when callbacks are simple one-liners.

class SessionsController < ApplicationController
  def create
    AuthenticateUser.prepare
      .on_success { |ctx| session[:user_id] = ctx.user.id; redirect_to root_path }
      .on_failure { |ctx| flash.now[:alert] = ctx.error; render :new }
      .call(email: params[:email], password: params[:password])
  end
end

# ── Pattern 4: Pattern matching ───────────────────────────────────────────────
# Explicit, works well with complex branching on error types.

class RegistrationsController < ApplicationController
  def create
    case RegisterUser.call(registration_params)
    in { success: true, user: User => user }
      sign_in(user)
      redirect_to dashboard_path, notice: "Welcome, #{user.name}!"
    in { success: false, errors: Hash => errs }
      @errors = errs
      render :new
    in { success: false, error: String => msg }
      flash.now[:alert] = msg
      render :new
    end
  end

  private

  def registration_params
    params.require(:registration).permit(:name, :email, :password, :plan)
  end
end

# ── Pattern 5: API controller ─────────────────────────────────────────────────

class Api::V1::UsersController < ApplicationController
  def create
    CreateUser.call(user_params)
      .on_success { |ctx| render json: ctx.user, status: :created }
      .on_failure { |ctx| render json: { error: ctx.error, errors: ctx.errors }, status: :unprocessable_entity }
  end

  private

  def user_params
    params.require(:user).permit(:name, :email)
  end
end

# ── Pattern 6: call! for operations expected to always succeed ────────────────
# Use in background jobs or orchestration where failure is exceptional.

class OrderProcessingJob < ApplicationJob
  def perform(order_id)
    order = Order.find(order_id)
    ctx   = FulfillOrder.call!(order: order)    # raises if fails
    ShipmentMailer.shipped(ctx.shipment).deliver_now
  rescue Easyop::Ctx::Failure => e
    Rails.logger.error "Order #{order_id} fulfillment failed: #{e.ctx.error}"
    raise  # re-raise for job retry
  end
end

# ── Pattern 7: Shared ApplicationOperation base ───────────────────────────────

class ApplicationOperation
  include Easyop::Operation

  rescue_from ActiveRecord::RecordInvalid do |e|
    ctx.fail!(
      error:  e.record.errors.full_messages.first,
      errors: e.record.errors.group_by_attribute.transform_values { |es| es.map(&:message) }
    )
  end

  rescue_from ActiveRecord::RecordNotFound do |e|
    ctx.fail!(error: "#{e.model} not found")
  end

  rescue_from StandardError do |e|
    Sentry.capture_exception(e)
    ctx.fail!(error: "An unexpected error occurred")
  end
end

class CreateUser < ApplicationOperation
  def call
    ctx.user = User.create!(name: ctx.name, email: ctx.email)
  end
end

class FindUser < ApplicationOperation
  def call
    ctx.user = User.find(ctx.user_id)  # RecordNotFound is caught above
  end
end
