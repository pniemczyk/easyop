module Payments
  # Charges a user's credit card for a given amount.
  #
  # Demonstrates:
  #   - encrypt_params: sensitive card data stored encrypted in params_data
  #     (stored as { "$easyop_encrypted" => "<ciphertext>" } in the log)
  #   - filter_params: billing_zip scrubbed but visible as [FILTERED]
  #   - record_result attrs: saves the Payment AR object reference
  #   - rescue_from: handles payment gateway errors gracefully
  #
  # The credit_card_number and cvv are NEVER stored in plaintext — decryption
  # requires the application secret. Admins can inspect that a card was charged
  # without ever seeing the PAN.
  class Charge < ApplicationOperation
    params do
      required :user,               User
      required :amount_cents,       :integer
      required :credit_card_number, :string
      required :cvv,                :string
      optional :billing_zip,        :string
      optional :tier,               :string, default: "standard"
    end

    # Sensitive card data: encrypted at rest in params_data.
    # Decrypt with: Easyop::SimpleCrypt.decrypt_marker(params["credit_card_number"])
    encrypt_params :credit_card_number, :cvv

    # Billing zip is sensitive but we still want to know THAT it was provided.
    filter_params :billing_zip

    # Capture the resulting Payment AR object reference in result_data.
    record_result attrs: %i[payment]

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Payment record error: #{e.message}")
    end

    def call
      # In a real app, call your payment gateway SDK here.
      # We simulate a successful charge by generating a transaction ID.
      txn_id = "txn_#{SecureRandom.hex(8)}"

      ctx.payment = Payment.create!(
        user:           ctx.user,
        amount_cents:   ctx.amount_cents,
        transaction_id: txn_id,
        status:         "completed"
      )
    end
  end
end
