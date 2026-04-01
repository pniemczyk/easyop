module Admin
  class PublishEvent < ApplicationOperation
    params do
      required :event, Event
    end

    def call
      ctx.fail!(error: "Event has no ticket types") if ctx.event.ticket_types.empty?
      ctx.event.update!(published: true)
    end
  end
end
