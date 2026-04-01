class OperationLog < ApplicationRecord
  validates :operation_name, presence: true
  validates :performed_at, presence: true

  scope :recent, -> { order(performed_at: :desc) }
  scope :successes, -> { where(success: true) }
  scope :failures, -> { where(success: false) }
  scope :for_operation, ->(name) { where(operation_name: name) }
  scope :order_related, -> {
    where("operation_name LIKE ?", "%Order%")
      .or(where("operation_name LIKE ?", "%Checkout%"))
      .or(where("operation_name LIKE ?", "%Payment%"))
      .or(where("operation_name LIKE ?", "%Ticket%"))
      .or(where("operation_name LIKE ?", "%Discount%"))
  }
end
