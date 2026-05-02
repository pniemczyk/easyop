module Tickets
  class DeliverTickets < ApplicationOperation
    plugin Easyop::Plugins::Async, queue: "deliveries"   # enables .async step modifier
    def call
      # Simulate ticket delivery (in a real app: send email)
      ctx.tickets.each do |ticket|
        ticket.update!(delivered_at: Time.current)
      end
      ctx.delivered = true
    end
  end
end
