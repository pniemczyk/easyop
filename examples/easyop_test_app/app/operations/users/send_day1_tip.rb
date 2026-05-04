module Users
  # Day-1 step in the OnboardUser durable flow (runs after wait: 1.day).
  # In production: send a tip email. Here: stamps the timestamp.
  class SendDay1Tip < ApplicationOperation
    def call
      ctx.day1_tip_sent_at = Time.current
      Rails.logger.info "[SendDay1Tip] Sent day-1 tip to user ##{ctx.user.id}"
    end
  end
end
