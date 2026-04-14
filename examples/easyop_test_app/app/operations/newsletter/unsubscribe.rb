module Newsletter
  # Unsubscribes an email address from the newsletter.
  # Demonstrates:
  #   - params schema
  #   - rescue_from with: :symbol for RecordNotFound
  class Unsubscribe < ApplicationOperation
    params do
      required :email, :string
    end

    # Domain event: downstream handlers (e.g. CRM sync) can react to unsubscribes.
    emits "newsletter.unsubscribed", on: :success,
          payload: ->(ctx) { { email: ctx.subscription.email } }

    rescue_from ActiveRecord::RecordNotFound, with: :handle_not_found

    def call
      sub = Subscription.find_by!(email: ctx.email.to_s.strip.downcase, unsubscribed_at: nil)
      sub.update!(unsubscribed_at: Time.current)
      ctx.subscription = sub
    end

    private

    def handle_not_found(_e)
      ctx.fail!(error: "No active subscription found for #{ctx.email}")
    end
  end
end
