module Admin
  class TicketTypesController < BaseController
    before_action :set_event
    before_action :set_ticket_type, only: [ :edit, :update, :destroy ]

    def create
      @ticket_type = @event.ticket_types.create!(ticket_type_params)
      redirect_to admin_event_path(@event), notice: "Ticket type added!"
    rescue => e
      redirect_to admin_event_path(@event), alert: e.message
    end

    def update
      @ticket_type.update!(ticket_type_params)
      redirect_to admin_event_path(@event), notice: "Ticket type updated!"
    rescue => e
      redirect_to admin_event_path(@event), alert: e.message
    end

    def destroy
      @ticket_type.destroy
      redirect_to admin_event_path(@event), notice: "Ticket type removed."
    end

    private

    def set_event
      @event = Event.find(params[:event_id])
    end

    def set_ticket_type
      @ticket_type = @event.ticket_types.find(params[:id])
    end

    def ticket_type_params
      params.require(:ticket_type).permit(:name, :description, :price_cents, :quantity)
    end
  end
end
