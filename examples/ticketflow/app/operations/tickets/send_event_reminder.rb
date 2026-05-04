module Tickets
  # Sends a reminder 24 hours before the event (scheduled via wait: in FulfillOrder).
  # In production: email/SMS the attendee. Here: stamps a timestamp.
  class SendEventReminder < ApplicationOperation
    rescue_from StandardError do |e|
      raise e
    end

    async_retry max_attempts: 2, wait: 10, backoff: :linear

    def call
      ctx.reminder_sent_at = Time.current
      Rails.logger.info "[SendEventReminder] Reminder sent for order ##{ctx.order.id}"
    end
  end
end
