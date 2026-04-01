class User < ApplicationRecord
  has_secure_password
  has_many :orders

  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true

  before_save { email.downcase! }

  scope :admins, -> { where(admin: true) }
end
