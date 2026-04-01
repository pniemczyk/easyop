class Order < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :event
  belongs_to :discount_code, optional: true
  has_many :order_items, dependent: :destroy
  has_many :tickets, dependent: :destroy

  validates :email, presence: true
  validates :name, presence: true
  validates :status, inclusion: { in: %w[pending paid refunded cancelled] }

  scope :paid, -> { where(status: "paid") }
  scope :recent, -> { order(created_at: :desc) }

  def total
    total_cents / 100.0
  end

  def subtotal
    subtotal_cents / 100.0
  end

  def discount
    discount_cents / 100.0
  end
end
