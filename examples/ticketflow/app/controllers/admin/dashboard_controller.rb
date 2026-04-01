module Admin
  class DashboardController < BaseController
    def index
      @total_revenue = Order.paid.sum(:total_cents) / 100.0
      @total_orders = Order.paid.count
      @total_tickets = Ticket.count
      @total_events = Event.count
      @recent_orders = Order.paid.recent.limit(10).includes(:event)
      @revenue_by_event = Event.joins(:orders)
                               .where(orders: { status: "paid" })
                               .group("events.title")
                               .sum("orders.total_cents")
    end
  end
end
