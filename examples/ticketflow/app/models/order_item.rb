class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type

  def subtotal_cents
    unit_price_cents * quantity
  end
end
