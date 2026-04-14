class OperationLog < ApplicationRecord
  validates :operation_name, :performed_at, presence: true
  validates :success, inclusion: { in: [true, false] }

  scope :successes,     -> { where(success: true) }
  scope :failures,      -> { where(success: false) }
  scope :for_operation, ->(name) { where(operation_name: name) }
  scope :recent,        -> { order(performed_at: :desc) }

  # Flow tracing — fetch all logs from the same execution tree, oldest-first.
  scope :for_tree,      ->(id) { where(root_reference_id: id).order(:performed_at) }

  # True when this log has no parent (it is the root of the flow tree).
  def root?
    parent_reference_id.nil?
  end
end
