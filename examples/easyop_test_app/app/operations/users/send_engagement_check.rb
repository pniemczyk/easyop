module Users
  # Day-7 step in the OnboardUser durable flow (runs after wait: 7.days).
  # In production: send an engagement nudge. Here: stamps the timestamp.
  class SendEngagementCheck < ApplicationOperation
    def call
      ctx.engagement_check_sent_at = Time.current
      Rails.logger.info "[SendEngagementCheck] Sent engagement check to user ##{ctx.user.id}"
    end
  end
end
