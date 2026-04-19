class PurchasesController < ApplicationController
  before_action :require_login

  def new
    @user = current_user
  end

  def create
    result = Flows::PurchaseAccess.call(
      user:               current_user,
      amount_cents:       params[:amount_cents].to_i,
      credit_card_number: params[:credit_card_number],
      cvv:                params[:cvv],
      billing_zip:        params[:billing_zip],
      tier:               params[:tier].presence || "standard"
    )

    if result.success?
      grant   = result.ctx.access_grant
      payment = result.ctx.payment
      redirect_to operation_logs_path,
        notice: "Purchase successful! #{grant.tier.capitalize} access granted. " \
                "Payment ##{payment.transaction_id}. " \
                "Check Op Logs to see the encrypted credit card in params_data."
    else
      @user = current_user
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end
end
