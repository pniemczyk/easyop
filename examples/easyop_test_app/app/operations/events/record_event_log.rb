module Events
  # Subscribes to all domain events ("**") and persists each one to EventLog.
  # Demonstrates:
  #   - Easyop::Plugins::EventHandlers — subscribes at class-load time
  #   - on "**" — wildcard that matches every event name regardless of depth
  #   - ctx.event  — the Easyop::Events::Event object delivered by the bus
  #   - recording false / transactional false — lightweight, no overhead
  class RecordEventLog < ApplicationOperation
    recording false
    transactional false

    plugin Easyop::Plugins::EventHandlers

    # "**" matches every event name: article.published, user.registered, etc.
    on "**"

    def call
      EventLog.create!(
        event_name:   ctx.event.name,
        source:       ctx.event.source,
        payload_data: ctx.event.payload.to_json,
        occurred_at:  ctx.event.timestamp
      )
    end
  end
end
