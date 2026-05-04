# frozen_string_literal: true

module Notifications
  # Step 3 of Flows::EngageAfterCheckout — fires at wait_until time (5 min after checkout in dev).
  # Sends an event reminder with venue details and what to bring.
  # In production: wait_until would be set to, e.g., the day before the event.
  # Replace with EventMailer.pre_event_reminder(ctx.order).deliver_now
  class SendPreEventReminder < ApplicationOperation
    def call
      order = ctx.order
      Rails.logger.info(
        "[Notifications::SendPreEventReminder] " \
        "Pre-event reminder — order ##{order.id} for #{order.email} " \
        "(#{order.event.title} @ #{order.event.venue}) " \
        "at #{Time.current.strftime('%H:%M:%S')}"
      )
      ctx.reminder_sent_at = Time.current
    end
  end
end
