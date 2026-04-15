module Tickets
  class GenerateTickets < ApplicationOperation
    # Record only the keys relevant for the audit log — skip the full order object.
    record_params attrs: %i[event_id seat_count]

    def call
      tickets = []

      ctx.order.order_items.each do |item|
        item.quantity.times do
          ticket = ctx.order.tickets.create!(
            ticket_type: item.ticket_type,
            attendee_name: ctx.order.name,
            attendee_email: ctx.order.email,
            status: "active"
          )
          tickets << ticket
        end
      end

      ctx.tickets = tickets
    end

    def rollback
      ctx.tickets&.each(&:destroy)
    end
  end
end
