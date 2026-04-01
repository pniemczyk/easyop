# Demonstrates:
#   - Transactional plugin: each step in the flow runs in its own AR transaction
#   - Rollback: if CreditRecipient or RecordTransfer fails, DebitSender rolls back
#   - prepare + on_success/on_failure pattern
#   - optional fee step via lambda guard in the flow
class TransfersController < ApplicationController
  before_action :require_login

  def new
    @users = User.where.not(id: current_user.id).order(:name)
  end

  def create
    recipient = User.find(params[:recipient_id])

    Flows::TransferCredits.prepare
      .on_success { |ctx| redirect_to root_path, notice: ctx.transfer_note }
      .on_failure { |ctx| flash[:alert] = ctx.error; redirect_to new_transfer_path }
      .call(
        sender:      current_user,
        recipient:   recipient,
        amount:      params[:amount].to_i,
        apply_fee:   params[:apply_fee] == "1"
      )
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = "Recipient not found."
    redirect_to new_transfer_path
  end
end
