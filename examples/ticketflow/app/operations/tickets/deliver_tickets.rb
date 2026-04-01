module Tickets
  class DeliverTickets < ApplicationOperation
    def call
      # Simulate ticket delivery (in a real app: send email)
      ctx.tickets.each do |ticket|
        ticket.update!(delivered_at: Time.current)
      end
      ctx.delivered = true
    end
  end
end
