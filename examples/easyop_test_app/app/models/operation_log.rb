class OperationLog < ApplicationRecord
  validates :operation_name, :performed_at, presence: true
  validates :success, inclusion: { in: [true, false] }

  scope :successes, -> { where(success: true) }
  scope :failures,  -> { where(success: false) }
  scope :for_operation, ->(name) { where(operation_name: name) }
  scope :recent, -> { order(performed_at: :desc) }
end
