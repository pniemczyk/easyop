module Orders
  class CalculateSubtotal < ApplicationOperation
    # ctx must have: cart (Hash of ticket_type_id => quantity), event

    def call
      items = []
      subtotal = 0

      ctx.cart.each do |ticket_type_id, quantity|
        quantity = quantity.to_i
        next if quantity <= 0

        ticket_type = ctx.event.ticket_types.find_by(id: ticket_type_id)
        ctx.fail!(error: "Invalid ticket type") unless ticket_type
        ctx.fail!(error: "#{ticket_type.name} is sold out") if ticket_type.available_count < quantity

        item_total = ticket_type.price_cents * quantity
        subtotal += item_total
        items << { ticket_type: ticket_type, quantity: quantity, unit_price_cents: ticket_type.price_cents }
      end

      ctx.fail!(error: "Please select at least one ticket") if items.empty?

      ctx.items = items
      ctx.subtotal_cents = subtotal
    end
  end
end
