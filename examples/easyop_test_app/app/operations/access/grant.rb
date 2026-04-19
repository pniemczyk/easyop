module Access
  # Grants a tier of premium access to a user after a successful payment.
  #
  # Demonstrates:
  #   - record_result attrs: captures the AccessGrant AR object in result_data
  #   - rescue_from: wraps AR errors
  class Grant < ApplicationOperation
    params do
      required :user,    User
      required :payment, Payment
      optional :tier,    :string, default: "standard"
    end

    record_result attrs: %i[access_grant]

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Could not grant access: #{e.message}")
    end

    def call
      ctx.access_grant = AccessGrant.create!(
        user:       ctx.user,
        payment:    ctx.payment,
        tier:       ctx.tier,
        granted_at: Time.current
      )
    end
  end
end
