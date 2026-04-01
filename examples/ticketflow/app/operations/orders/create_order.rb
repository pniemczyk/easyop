module Orders
  class CreateOrder < ApplicationOperation
    params do
      required :event, Event
      required :items, Array
      required :email, String
      required :name, String
      required :subtotal_cents, Integer
    end

    def call
      discount_cents = ctx[:discount_cents].to_i
      total_cents = [ ctx.subtotal_cents - discount_cents, 0 ].max

      order = Order.create!(
        event: ctx.event,
        user: ctx[:current_user],
        email: ctx.email,
        name: ctx.name,
        subtotal_cents: ctx.subtotal_cents,
        discount_cents: discount_cents,
        total_cents: total_cents,
        discount_code: ctx[:discount_code],
        status: "pending"
      )

      ctx.items.each do |item|
        order.order_items.create!(
          ticket_type: item[:ticket_type],
          quantity: item[:quantity],
          unit_price_cents: item[:unit_price_cents]
        )
      end

      ctx.order = order
    end

    def rollback
      ctx.order&.destroy
    end
  end
end
