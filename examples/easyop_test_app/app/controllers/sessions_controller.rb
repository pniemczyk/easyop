# Demonstrates: .call.on_success { }.on_failure { } chaining
class SessionsController < ApplicationController
  def new
    redirect_to root_path, notice: "Already logged in." if logged_in?
  end

  def create
    Users::Authenticate.call(session_params)
      .on_success { |ctx| session[:user_id] = ctx.user.id; redirect_to root_path, notice: "Welcome back, #{ctx.user.name}!" }
      .on_failure { |ctx| flash.now[:alert] = ctx.error; render :new, status: :unprocessable_entity }
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path, notice: "You have been logged out."
  end

  private

  def session_params
    params.require(:session).permit(:email, :password)
  end
end
