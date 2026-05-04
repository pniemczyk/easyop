module Users
  # Day-0 step in the OnboardUser durable flow.
  # In production: send a real welcome email. Here: stamps the timestamp.
  class SendWelcomeEmail < ApplicationOperation
    def call
      ctx.welcome_sent_at = Time.current
      Rails.logger.info "[SendWelcomeEmail] Sent welcome email to user ##{ctx.user.id}"
    end
  end
end
