# Demonstrates: FlowBuilder.prepare.bind_with(self).on(success:, fail:)
class RegistrationsController < ApplicationController
  def new
    redirect_to root_path, notice: "Already registered and logged in." if logged_in?
  end

  def create
    Flows::CompleteRegistration.prepare
      .bind_with(self)
      .on(success: :registration_succeeded, fail: :registration_failed)
      .call(registration_params)
  end

  private

  def registration_params
    params.require(:registration).permit(:email, :name, :password, :newsletter_opt_in)
      .merge(newsletter_opt_in: params.dig(:registration, :newsletter_opt_in) == "1")
  end

  def registration_succeeded(ctx)
    session[:user_id] = ctx.user.id
    redirect_to root_path, notice: "Welcome, #{ctx.user.name}! Your account has been created."
  end

  def registration_failed(ctx)
    @errors = ctx.errors
    flash.now[:alert] = ctx.error || "Registration failed. Please try again."
    render :new, status: :unprocessable_entity
  end
end
