class OperationLog < ApplicationRecord
  validates :operation_name, presence: true
  validates :performed_at, presence: true

  scope :recent,        -> { order(performed_at: :desc) }
  scope :successes,     -> { where(success: true) }
  scope :failures,      -> { where(success: false) }
  scope :for_operation, ->(name) { where(operation_name: name) }

  # Flow tracing — fetch all logs from the same execution tree, oldest-first.
  scope :for_tree,      ->(id) { where(root_reference_id: id).order(:performed_at) }

  # True when this log has no parent (it is the root of the flow tree).
  def root?
    parent_reference_id.nil?
  end

  scope :order_related, -> {
    where("operation_name LIKE ?", "%Order%")
      .or(where("operation_name LIKE ?", "%Checkout%"))
      .or(where("operation_name LIKE ?", "%Payment%"))
      .or(where("operation_name LIKE ?", "%Ticket%"))
      .or(where("operation_name LIKE ?", "%Discount%"))
  }
end
