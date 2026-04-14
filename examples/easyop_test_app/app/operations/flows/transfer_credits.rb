# Demonstrates:
#   - Transactional plugin: each step runs in its own AR transaction (from ApplicationOperation)
#   - Rollback: Steps undo DB changes if a later step fails
#   - skip_if (via lambda guard): optional fee step
#   - complex ctx sharing across steps
#   - transactional false on the Flow itself (each step manages its own transaction)
class Flows::TransferCredits < ApplicationOperation
  include Easyop::Flow
  transactional false  # each step manages its own AR transaction

  # ── Debit the sender's credit balance ──────────────────────────────────────
  class DebitSender < ApplicationOperation
    params do
      required :sender, User
      required :amount, :integer
    end

    def call
      ctx.fail!(error: "Insufficient credits") if ctx.sender.credits < ctx.amount
      ctx.sender.decrement!(:credits, ctx.amount)
    end

    def rollback
      ctx.sender.increment!(:credits, ctx.amount)
      Rails.logger.info "[TransferCredits::DebitSender] Rolled back #{ctx.amount} credits to #{ctx.sender.name}"
    end
  end

  # ── Optional 2% processing fee ─────────────────────────────────────────────
  class ApplyFee < ApplicationOperation
    skip_if { |c| !c[:apply_fee] }

    def call
      ctx.fee    = (ctx.amount * 0.02).ceil
      ctx.amount = ctx.amount - ctx.fee
    end
  end

  # ── Credit the recipient's balance ─────────────────────────────────────────
  class CreditRecipient < ApplicationOperation
    params do
      required :recipient, User
      required :amount,    :integer
    end

    def call
      ctx.recipient.increment!(:credits, ctx.amount)
    end

    def rollback
      ctx.recipient.decrement!(:credits, ctx.amount)
      Rails.logger.info "[TransferCredits::CreditRecipient] Rolled back #{ctx.amount} credits from #{ctx.recipient.name}"
    end
  end

  # ── Record the transfer in ctx (no DB model needed) ────────────────────────
  class RecordTransfer < ApplicationOperation
    def call
      fee_note = ctx[:fee] ? " (fee: #{ctx.fee} credit#{"s" if ctx.fee != 1})" : ""
      ctx.transfer_note = "#{ctx.sender.name} → #{ctx.recipient.name}: #{ctx.amount} credit#{"s" if ctx.amount != 1}#{fee_note}"
    end
  end

  # ── Declare steps after inner classes are defined ──────────────────────────
  flow DebitSender,
       ->(ctx) { ctx[:apply_fee] },
       ApplyFee,
       CreditRecipient,
       RecordTransfer
end
