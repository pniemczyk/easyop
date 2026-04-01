class Broadcast < ApplicationRecord
  belongs_to :article, optional: true

  validates :subject, presence: true
  validates :body, presence: true
end
