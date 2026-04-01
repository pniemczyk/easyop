module Admin
  class RefundOrder < ApplicationOperation
    params do
      required :order, Order
    end

    def call
      ctx.fail!(error: "Order is not paid") unless ctx.order.status == "paid"

      ctx.order.update!(status: "refunded")
      ctx.order.tickets.update_all(status: "cancelled")

      # Return ticket counts
      ctx.order.order_items.each do |item|
        item.ticket_type.decrement!(:sold_count, item.quantity)
      end

      ctx.order.discount_code&.decrement!(:use_count)
    end
  end
end
