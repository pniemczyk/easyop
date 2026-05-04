# frozen_string_literal: true

module Notifications
  # Step 2 of Flows::EngageAfterCheckout — fires ~4 seconds after checkout.
  # Sends a "your tickets are ready" email with download links.
  # In production: replace with TicketsMailer.tickets_ready(ctx.order).deliver_now
  class SendTicketsReady < ApplicationOperation
    def call
      order = ctx.order
      Rails.logger.info(
        "[Notifications::SendTicketsReady] " \
        "Tickets ready — order ##{order.id} for #{order.email} " \
        "(ticket codes: #{order.tickets.pluck(:ticket_code).join(', ')}) " \
        "at #{Time.current.strftime('%H:%M:%S')}"
      )
      ctx.tickets_ready_sent_at = Time.current
    end
  end
end
