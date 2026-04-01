class TicketType < ApplicationRecord
  belongs_to :event
  has_many :order_items
  has_many :tickets

  validates :name, presence: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity, numericality: { greater_than: 0 }

  def price
    price_cents / 100.0
  end

  def available_count
    quantity - sold_count
  end

  def sold_out?
    available_count <= 0
  end
end
