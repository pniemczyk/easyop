class EventsController < ApplicationController
  def index
    @events = Event.published.upcoming.order(:starts_at)
  end

  def show
    @event = Event.published.find_by!(slug: params[:slug])
    @ticket_types = @event.ticket_types
  end
end
