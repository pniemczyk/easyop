# Demonstrates: .call.on_success { }.on_failure { } chaining
class SubscriptionsController < ApplicationController
  def new
  end

  def create
    Newsletter::Subscribe.call(subscribe_params)
      .on_success { |ctx| redirect_to root_path, notice: "Subscribed! Check your email to confirm." }
      .on_failure { |ctx| flash[:alert] = ctx.error; redirect_to new_subscription_path }
  end

  def destroy
    Newsletter::Unsubscribe.call(email: params[:id])
      .on_success { |ctx| redirect_to root_path, notice: "You've been unsubscribed." }
      .on_failure { |ctx| redirect_to root_path, alert: ctx.error }
  end

  private

  def subscribe_params
    params.require(:subscription).permit(:email, :name)
  end
end
