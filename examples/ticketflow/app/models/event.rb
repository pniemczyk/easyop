class Event < ApplicationRecord
  has_many :ticket_types, dependent: :destroy
  has_many :orders

  before_save :generate_slug

  scope :published, -> { where(published: true) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }

  def total_tickets_sold
    ticket_types.sum(:sold_count)
  end

  def total_revenue_cents
    orders.where(status: "paid").sum(:total_cents)
  end

  private

  def generate_slug
    self.slug ||= title.to_s.parameterize + "-" + SecureRandom.hex(4)
  end
end
