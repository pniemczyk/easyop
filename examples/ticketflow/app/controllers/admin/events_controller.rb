module Admin
  class EventsController < BaseController
    before_action :set_event, only: [ :show, :edit, :update, :destroy, :publish ]

    def index
      @events = Event.order(created_at: :desc)
    end

    def show
      @ticket_types = @event.ticket_types
      @orders = @event.orders.paid.recent.limit(20)
    end

    def new
      @event = Event.new
    end

    def create
      result = ::Admin::CreateEvent.call(**event_params.to_h.symbolize_keys)
      if result.success?
        redirect_to admin_event_path(result.event), notice: "Event created!"
      else
        @event = Event.new(event_params)
        flash.now[:alert] = result.error
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @event.update(event_params)
        redirect_to admin_event_path(@event), notice: "Event updated!"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @event.destroy
      redirect_to admin_events_path, notice: "Event deleted."
    end

    def publish
      result = ::Admin::PublishEvent.call(event: @event)
      if result.success?
        redirect_to admin_event_path(@event), notice: "Event published!"
      else
        redirect_to admin_event_path(@event), alert: result.error
      end
    end

    private

    def set_event
      @event = Event.find(params[:id])
    end

    def event_params
      params.require(:event).permit(:title, :description, :venue, :location, :starts_at, :ends_at, :cover_color)
    end
  end
end
