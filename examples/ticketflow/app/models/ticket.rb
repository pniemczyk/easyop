class Ticket < ApplicationRecord
  belongs_to :order
  belongs_to :ticket_type

  validates :token, presence: true, uniqueness: true

  scope :active, -> { where(status: "active") }
  scope :delivered, -> { where.not(delivered_at: nil) }

  before_validation :generate_token, on: :create

  def delivered?
    delivered_at.present?
  end

  private

  def generate_token
    self.token ||= "TF-#{SecureRandom.hex(8).upcase}"
  end
end
