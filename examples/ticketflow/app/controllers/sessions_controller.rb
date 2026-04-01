class SessionsController < ApplicationController
  def new; end

  def create
    result = Users::Authenticate.call(email: params[:email], password: params[:password])
    if result.success?
      session[:user_id] = result.user.id
      redirect_to root_path, notice: "Welcome back, #{result.user.name}!"
    else
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path, notice: "Logged out."
  end
end
