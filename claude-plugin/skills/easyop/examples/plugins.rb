# frozen_string_literal: true

# EasyOp — Plugin Examples
# Shows all four built-in plugins and how to build a custom plugin.
# These are illustrative patterns, not runnable standalone scripts.

# ── Setup — base operation class ─────────────────────────────────────────────

require "easyop/plugins/instrumentation"
require "easyop/plugins/recording"
require "easyop/plugins/async"
require "easyop/plugins/transactional"

class ApplicationOperation
  include Easyop::Operation

  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording,    model: OperationLog
  plugin Easyop::Plugins::Async,        queue: "operations"
  plugin Easyop::Plugins::Transactional
end

# Inspect installed plugins:
ApplicationOperation._registered_plugins
# => [
#      { plugin: Easyop::Plugins::Instrumentation, options: {} },
#      { plugin: Easyop::Plugins::Recording, options: { model: OperationLog } },
#      { plugin: Easyop::Plugins::Async, options: { queue: "operations" } },
#      { plugin: Easyop::Plugins::Transactional, options: {} }
#    ]

# ── Plugin execution order ────────────────────────────────────────────────────
#
# Plugins wrap _easyop_run via prepend. The last installed is the outermost:
#
#   Transactional::RunWrapper  (outermost — last installed)
#     Recording::RunWrapper
#       Instrumentation::RunWrapper
#         prepare { before → call → after }  (innermost)
#
# This means:
# - The DB transaction opens first and closes last.
# - Recording measures wall time that includes the transaction overhead.
# - Instrumentation event fires inside the transaction and recording window.

# ── Plugin 1: Instrumentation ─────────────────────────────────────────────────

# config/initializers/easyop.rb — attach the built-in log subscriber:
Easyop::Plugins::Instrumentation.attach_log_subscriber
# Every call now logs:
#   [EasyOp] Users::Register ok (4.2ms)
#   [EasyOp] Users::Authenticate FAILED (1.1ms) — Invalid email or password

# Subscribe manually for custom APM:
ActiveSupport::Notifications.subscribe("easyop.operation.call") do |event|
  p = event.payload
  MyAPM.record_span(
    p[:operation],
    success:  p[:success],
    error:    p[:error],
    duration: p[:duration]  # Float ms
  )
end

# ── Plugin 2: Recording ───────────────────────────────────────────────────────

# Migration:
#   create_table :operation_logs do |t|
#     t.string   :operation_name, null: false
#     t.boolean  :success,        null: false
#     t.string   :error_message
#     t.text     :params_data          # JSON — ctx attrs with sensitive keys scrubbed
#     t.float    :duration_ms
#     t.datetime :performed_at,   null: false
#   end

# Default: all ops are recorded. Opt out per class:
class Newsletter::SendBroadcast < ApplicationOperation
  recording false   # skip logging for this operation
end

# Disable params serialization for high-frequency or sensitive ops:
class Users::TrackPageView < ApplicationOperation
  plugin Easyop::Plugins::Recording, model: OperationLog, record_params: false
end

# Scrubbed keys (never appear in params_data):
# :password, :password_confirmation, :token, :secret, :api_key
# ActiveRecord objects are serialized as { "id" => 42, "class" => "User" }

# ── Plugin 3: Async ─���─────────────────────────────────────────────────────────

class Reports::GeneratePDF < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "reports"

  def call
    ctx.pdf = PdfGenerator.run(ctx.report_id)
  end
end

# Enqueue immediately:
Reports::GeneratePDF.call_async(report_id: 123)

# With delay:
Reports::GeneratePDF.call_async(report_id: 123, wait: 5.minutes)

# At a specific time:
Reports::GeneratePDF.call_async(report_id: 123, wait_until: Date.tomorrow.noon)

# Override queue at call time:
Reports::GeneratePDF.call_async(report_id: 123, queue: "low_priority")

# ActiveRecord objects are auto-serialized (class + id) and re-fetched in the job:
class Orders::SendConfirmation < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "mailer"
end

Orders::SendConfirmation.call_async(order: @order, user: current_user)
# => Serialized as: { "order" => { "__ar_class" => "Order", "__ar_id" => 42 },
#                     "user"  => { "__ar_class" => "User",  "__ar_id" => 7  } }

# The job class is created lazily on first call_async:
Easyop::Plugins::Async::Job  # => the ActiveJob subclass

# ── Plugin 4: Transactional ───────────────────────────────────────────────────

class TransferFunds < ApplicationOperation
  plugin Easyop::Plugins::Transactional

  def call
    ctx.from_account.debit!(ctx.amount)
    ctx.to_account.credit!(ctx.amount)
    ctx.transaction_id = SecureRandom.uuid
  end
end

# If ctx.fail! is called (or any unhandled exception is raised), the transaction
# rolls back automatically. ctx.failure? will be true and the DB is clean.

# Opt out for read-only operations when parent has transactions enabled:
class AccountSummaryReport < ApplicationOperation
  transactional false   # no transaction overhead
end

# Works with include style too:
class LegacyOp
  include Easyop::Operation
  include Easyop::Plugins::Transactional
end

# With Flow: apply Transactional to the Flow class for a flow-wide transaction:
class ProcessOrder
  include Easyop::Flow
  plugin Easyop::Plugins::Transactional  # entire flow runs in one transaction

  flow ValidateCart, ChargePayment, CreateOrder
end

# ── Building a custom plugin ──────────────────────────────────────────────────

require "easyop/plugins/base"

module TimingPlugin
  def self.install(base, threshold_ms: 500, **_opts)
    base.prepend(RunWrapper)
    base.extend(ClassMethods)
    base.instance_variable_set(:@_timing_threshold_ms, threshold_ms)
  end

  module ClassMethods
    # Per-class opt-out: `timing false`
    def timing(enabled)
      @_timing_enabled = enabled
    end

    def _timing_enabled?
      return @_timing_enabled if instance_variable_defined?(:@_timing_enabled)
      superclass.respond_to?(:_timing_enabled?) ? superclass._timing_enabled? : true
    end

    def _timing_threshold_ms
      @_timing_threshold_ms ||
        (superclass.respond_to?(:_timing_threshold_ms) ? superclass._timing_threshold_ms : 500)
    end
  end

  module RunWrapper
    def _easyop_run(ctx, raise_on_failure:)
      return super unless self.class._timing_enabled?

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super.tap do
        ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        if ms > self.class._timing_threshold_ms
          logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : Logger.new($stdout)
          logger.warn "[SLOW] #{self.class.name} took #{ms.round(1)}ms " \
                      "(threshold: #{self.class._timing_threshold_ms}ms)"
        end
      end
    end
  end
end

# Activate on your base class:
class ApplicationOperation
  plugin TimingPlugin, threshold_ms: 200
end

# Opt out for fast operations:
class Cache::Lookup < ApplicationOperation
  timing false
end
