class AccessGrant < ApplicationRecord
  belongs_to :user
  belongs_to :payment

  validates :granted_at, :tier, presence: true

  scope :active,   -> { where(revoked_at: nil) }
  scope :revoked,  -> { where.not(revoked_at: nil) }

  def active?
    revoked_at.nil?
  end
end
