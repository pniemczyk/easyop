class DiscountCode < ApplicationRecord
  has_many :orders

  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :amount, numericality: { greater_than: 0 }

  scope :active, -> { where(active: true) }

  def valid_for_use?
    return false unless active?
    return false if expires_at && expires_at < Time.current
    return false if max_uses && use_count >= max_uses
    true
  end

  def calculate_discount(subtotal_cents)
    if discount_type == "percentage"
      (subtotal_cents * amount / 100.0).round
    else
      [ amount, subtotal_cents ].min
    end
  end
end
