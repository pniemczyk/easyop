# Persists every domain event published via the EasyOp event bus.
# Written by Events::RecordEventLog (an EventHandlers operation that subscribes to "**").
class EventLog < ApplicationRecord
  validates :event_name, presence: true
  validates :occurred_at, presence: true

  scope :recent,      -> { order(occurred_at: :desc) }
  scope :for_event,   ->(name) { where(event_name: name) }

  # Returns payload_data parsed as a Hash; falls back to {}.
  def payload
    JSON.parse(payload_data, symbolize_names: false)
  rescue StandardError
    {}
  end
end
