class CheckoutsController < ApplicationController
  def new
    @event = Event.published.find_by!(slug: params[:event_slug])
    @ticket_types = @event.ticket_types.reject(&:sold_out?)
  end

  def create
    @event = Event.published.find_by!(slug: params[:event_slug])

    Flows::Checkout.prepare
      .on_success { |ctx| redirect_to order_confirmation_path(ctx.order) }
      .on_failure { |ctx|
        flash.now[:alert] = ctx.error
        @ticket_types = @event.ticket_types.reject(&:sold_out?)
        render :new, status: :unprocessable_entity
      }
      .call(
        event: @event,
        cart: params[:cart].to_unsafe_h,
        email: params[:email],
        name: params[:name],
        coupon_code: params[:coupon_code],
        current_user: current_user
      )
  end

  def confirmation
    @order = Order.find(params[:order_id])
    @tickets = @order.tickets.includes(:ticket_type)
  end
end
