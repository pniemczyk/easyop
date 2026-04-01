module Newsletter
  # Subscribes an email address to the newsletter.
  # Demonstrates:
  #   - skip_if guard — skips silently if already subscribed
  #   - params schema with :string type shorthand
  #   - before hook (symbol) for email normalization
  #   - rescue_from with block
  class Subscribe < ApplicationOperation
    # skip_if — silently skip this operation if already subscribed
    # The flow lambda guard provides a first layer; this is a second safety net
    skip_if { |c| Subscription.exists?(email: c.email.to_s.strip.downcase, unsubscribed_at: nil) }

    params do
      required :email, :string
      optional :name,  :string, default: ""
    end

    before :normalize_email

    rescue_from ActiveRecord::RecordInvalid do |e|
      ctx.fail!(error: "Could not subscribe", errors: e.record.errors.to_h)
    end

    def call
      ctx.subscription = Subscription.create!(
        email:     ctx.email,
        name:      ctx.name,
        confirmed: false
      )
    end

    private

    def normalize_email
      ctx.email = ctx.email.to_s.strip.downcase
    end
  end
end
