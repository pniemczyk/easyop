module Admin
  class OrdersController < BaseController
    before_action :set_order, only: [ :show, :refund ]

    def index
      @orders = Order.recent.includes(:event, :user, :tickets).limit(50)
      @orders = @orders.where(status: params[:status]) if params[:status].present?
      @orders = @orders.where(event_id: params[:event_id]) if params[:event_id].present?
    end

    def show
      @tickets = @order.tickets.includes(:ticket_type)
      @logs = OperationLog.order_related.recent.limit(20)
    end

    def refund
      result = ::Admin::RefundOrder.call(order: @order)
      if result.success?
        redirect_to admin_order_path(@order), notice: "Order refunded."
      else
        redirect_to admin_order_path(@order), alert: result.error
      end
    end

    private

    def set_order
      @order = Order.find(params[:id])
    end
  end
end
