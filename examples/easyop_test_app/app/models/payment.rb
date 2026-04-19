class Payment < ApplicationRecord
  belongs_to :user
  has_one :access_grant

  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :transaction_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[pending completed refunded failed] }

  scope :completed, -> { where(status: "completed") }
  scope :refunded,  -> { where(status: "refunded") }

  def amount_dollars
    amount_cents / 100.0
  end
end
