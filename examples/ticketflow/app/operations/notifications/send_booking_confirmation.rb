# frozen_string_literal: true

module Notifications
  # Step 1 of Flows::EngageAfterCheckout — fires ~2 seconds after checkout.
  # Sends a "booking confirmed" email with order summary.
  # In production: replace the logger call with OrderMailer.booking_confirmation(ctx.order).deliver_now
  class SendBookingConfirmation < ApplicationOperation
    def call
      order = ctx.order
      Rails.logger.info(
        "[Notifications::SendBookingConfirmation] " \
        "Booking confirmed — order ##{order.id} for #{order.email} " \
        "(#{order.tickets.count} ticket(s), #{order.event.title}) " \
        "at #{Time.current.strftime('%H:%M:%S')}"
      )
      ctx.confirmation_sent_at = Time.current
    end
  end
end
