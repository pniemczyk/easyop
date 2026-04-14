# Base operation — all app operations inherit from this.
# Demonstrates:
#   - plugin DSL (all four EasyOp plugins)
#   - around hook (symbol) for timing
#   - rescue_from StandardError with block
#   - Instrumentation: ActiveSupport::Notifications event per call
#   - Recording: persists every execution to OperationLog
#   - Async: all subclasses gain .call_async
#   - Transactional: wraps every operation in an AR transaction (opt out with `transactional false`)
require "easyop/plugins/base"
require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/async"
require "easyop/plugins/transactional"

class ApplicationOperation
  include Easyop::Operation

  # ── Plugins ────────────────────────────────────────────────────────────────
  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording, model: OperationLog
  plugin Easyop::Plugins::Async, queue: "operations"
  plugin Easyop::Plugins::Transactional
  # Events plugin: subclasses declare `emits` to publish domain events.
  # No events are emitted unless `emits` is declared on the subclass.
  plugin Easyop::Plugins::Events

  # ── Global rescue handler ──────────────────────────────────────────────────
  rescue_from StandardError do |e|
    Rails.logger.error "[#{self.class.name}] Unexpected error: #{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    ctx.fail!(error: "An unexpected error occurred. Please try again.")
  end
end
