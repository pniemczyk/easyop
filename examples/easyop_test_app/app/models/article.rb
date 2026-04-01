class Article < ApplicationRecord
  belongs_to :user

  validates :title, presence: true
  validates :body, presence: true

  scope :published, -> { where(published: true) }
  scope :drafts, -> { where(published: false) }
end
