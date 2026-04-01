class RegistrationsController < ApplicationController
  def new; end

  def create
    result = Users::Register.call(
      email: params[:email],
      name: params[:name],
      password: params[:password],
      password_confirmation: params[:password_confirmation]
    )
    if result.success?
      session[:user_id] = result.user.id
      redirect_to root_path, notice: "Welcome, #{result.user.name}!"
    else
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end
end
