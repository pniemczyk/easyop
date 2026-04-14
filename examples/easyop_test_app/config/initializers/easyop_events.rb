# Configure the EasyOp domain event bus.
#
# Uses the in-process Memory bus (default) — synchronous, zero extra dependencies.
# Swap for :active_support or a custom adapter (Redis, RabbitMQ, etc.) as the app grows.
#
#   Easyop::Events::Registry.bus = :active_support  # ActiveSupport::Notifications
#   Easyop::Events::Registry.bus = MyRabbitBus.new  # custom Easyop::Events::Bus::Adapter
#
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"
require "easyop/plugins/event_handlers"

Easyop::Events::Registry.bus = :memory

# Eager-load the event handler so its `on "**"` declaration registers the
# subscription at boot time — in development Rails lazy-loads app code by default,
# which would delay registration until the class is first referenced.
Rails.application.config.after_initialize do
  Events::RecordEventLog
end
