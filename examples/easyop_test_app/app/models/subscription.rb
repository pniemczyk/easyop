class Subscription < ApplicationRecord
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  scope :active, -> { where(unsubscribed_at: nil) }
  scope :confirmed, -> { where(confirmed: true) }
end
