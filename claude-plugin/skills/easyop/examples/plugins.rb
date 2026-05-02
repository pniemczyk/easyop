# frozen_string_literal: true

# EasyOp — Plugin Examples
# Shows all built-in plugins (Instrumentation, Recording, Async, Transactional,
# Events, EventHandlers) and how to build a custom plugin.
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

# Minimum migration:
#   create_table :operation_logs do |t|
#     t.string   :operation_name, null: false
#     t.boolean  :success,        null: false
#     t.string   :error_message
#     t.text     :params_data          # JSON — ctx attrs (sensitive keys replaced with [FILTERED])
#     t.float    :duration_ms
#     t.datetime :performed_at,   null: false
#   end

# Optional flow-tracing columns (add to enable call-tree reconstruction):
#   add_column :operation_logs, :root_reference_id,     :string
#   add_column :operation_logs, :reference_id,          :string
#   add_column :operation_logs, :parent_operation_name, :string
#   add_column :operation_logs, :parent_reference_id,   :string
#   add_index  :operation_logs, :root_reference_id
#   add_index  :operation_logs, :reference_id, unique: true
#   add_index  :operation_logs, :parent_reference_id
#
# Optional execution order column — 1-based index among siblings (nil for root):
#   add_column :operation_logs, :execution_index, :integer
#   add_index  :operation_logs, [:parent_reference_id, :execution_index],
#              name: 'index_operation_logs_on_parent_ref_and_exec_index'
#
# When these columns exist, nested flows are automatically linked and ordered:
#
#   FullCheckout.call(...)
#   # root_reference_id: "aaa"  ref: "bbb"  parent: nil          idx: nil
#     AuthAndValidate.call(...)
#     # root_reference_id: "aaa"  ref: "ccc"  parent: "bbb"  idx: 1
#       AuthenticateUser.call(...)
#       # root_reference_id: "aaa"  ref: "ddd"  parent: "ccc"  idx: 1
#     ProcessPayment.call(...)
#     # root_reference_id: "aaa"  ref: "eee"  parent: "bbb"  idx: 2
#
# Each child's counter resets under its own parent — AuthenticateUser starts at 1
# under AuthAndValidate even though AuthAndValidate itself is index 1 under FullCheckout.
#
# Useful model helpers:
#   scope :for_tree,    ->(id)  { where(root_reference_id: id).order(:performed_at) }
#   scope :children_of, ->(ref) { where(parent_reference_id: ref).order(:execution_index) }
#   def root?; parent_reference_id.nil?; end
#
# Query the full execution tree for a given root:
#   root_log = OperationLog.find_by(operation_name: "FullCheckout", parent_reference_id: nil)
#   OperationLog.for_tree(root_log.root_reference_id)
#   # => all 4 records, oldest-first, showing the full call tree
#
#   # Direct children of FullCheckout in call order:
#   OperationLog.children_of(root_log.reference_id)
#   # => [AuthAndValidate (idx:1), ProcessPayment (idx:2)]

# Optional result column — add when you want to capture output data:
#   add_column :operation_logs, :result_data, :text  # stored as JSON

# record_params DSL — four forms for controlling params_data:
#
# KEY BEHAVIOR: the default true form records only INPUT keys — the keys
# present in ctx BEFORE the operation body runs. Values set during #call
# (like ctx.user = User.create!(...)) are excluded from params_data and
# should be captured via record_result instead.
# Custom forms (attrs/block/symbol) are evaluated AFTER the call body, so
# they can access computed values if explicitly requested.
#
# Form 1: false — disable params recording entirely
class Users::Authenticate < ApplicationOperation
  record_params false   # keeps the audit trail but hides auth inputs
end

# Form 2: attrs — only selected ctx keys
class Tickets::GenerateTickets < ApplicationOperation
  record_params attrs: %i[event_id seat_count]
end

# Form 3: block — full custom extraction
class Reports::GeneratePdf < ApplicationOperation
  record_params { |ctx| { report_type: ctx.report_type, page_count: ctx.pages } }
end

# Form 4: symbol — delegates to a private instance method
class Payments::BuildPayload < ApplicationOperation
  record_params :safe_params

  private

  def safe_params
    { user_id: ctx.user.id, amount_cents: ctx.amount_cents }
  end
end

# Plugin-level default — all subclasses inherit unless they declare their own:
#   plugin Easyop::Plugins::Recording, model: OperationLog,
#          record_params: { attrs: %i[user_id plan] }
#   # also: record_params: ->(ctx) { { custom: ctx[:key] } }
#   # also: record_params: :build_params
#   # also: record_params: false  (disable for all)

# IMPORTANT: FILTERED_KEYS are always applied to the final hash, regardless of form.
# Even a custom block or attrs list — if it includes :password, it becomes "[FILTERED]".

# record_result DSL — four forms for capturing output in result_data:
#
# Form 1: true — full ctx snapshot (FILTERED_KEYS applied, internal keys excluded)
class Users::Register < ApplicationOperation
  record_result true   # captures the full output ctx after registration
end

# Form 2: attrs — one or more ctx keys
class PlaceOrder < ApplicationOperation
  record_result attrs: :order_id
end

class ProcessPayment < ApplicationOperation
  record_result attrs: [:charge_id, :amount_cents]
end

# Form 3: block — custom extraction logic
class GenerateReport < ApplicationOperation
  record_result { |ctx| { rows: ctx.rows.count, format: ctx.format } }
end

# Form 4: symbol — delegates to a private instance method
class BuildInvoice < ApplicationOperation
  record_result :build_result

  private

  def build_result
    { invoice_id: ctx.invoice.id, total: ctx.total }
  end
end

# Plugin-level default — all subclasses inherit unless they declare their own record_result:
#   plugin Easyop::Plugins::Recording, model: OperationLog,
#          record_result: true
#   # also: record_result: { attrs: :metadata }
#   # also: record_result: ->(ctx) { { id: ctx.record_id } }
#   # also: record_result: :build_result

# Filtering params — sensitive keys are kept in params_data but their value is
# replaced with "[FILTERED]". All filter layers are additive (built-in FILTERED_KEYS
# are always applied, and no layer replaces another):

# Layer 1 — global config (applied to every recorded operation):
Easyop.configure { |c| c.recording_filter_keys = [:api_token, /token/i] }

# Layer 2 — plugin install option (applied to all subclasses):
class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Recording, model: OperationLog, filter_keys: [:stripe_secret]
end

# Layer 3 — class DSL (inherited + stackable):
class ApplicationOperation
  filter_params :internal_ref, /access.?key/i
end

class Payments::ChargeCard < ApplicationOperation
  filter_params :card_number   # stacks on top of ApplicationOperation's list
  # Final filter list for Payments::ChargeCard:
  # FILTERED_KEYS + global config + :stripe_secret + :internal_ref + /access.?key/i + :card_number
  # All matched keys appear in params_data with value "[FILTERED]"
end

# Default: all ops are recorded. Opt out per class:
class Newsletter::SendBroadcast < ApplicationOperation
  recording false   # skip logging for this operation
end

# Filtered keys (kept in params_data, value replaced with "[FILTERED]"):
# :password, :password_confirmation, :token, :secret, :api_key
# Internal tracing keys (__recording_*) are fully removed from params_data.
# ActiveRecord objects are serialized as { "id" => 42, "class" => "User" }

# ── Flow + Recording: full call-tree tracing ──────────────────────────────────
#
# For the flow itself to appear in operation_logs as the tree root, inherit from
# ApplicationOperation and add transactional false (each step manages its own
# transaction; EasyOp's rollback handles compensation in reverse order).
#
require "easyop/flow"

class ProcessCheckout < ApplicationOperation
  include Easyop::Flow
  transactional false  # steps own their AR transactions

  flow ValidateCart, ChargePayment, CreateOrder
end

# Result in operation_logs (with flow-tracing + execution_index columns present):
#   ProcessCheckout   root=aaa  ref=bbb  parent=nil         idx=nil
#     ValidateCart    root=aaa  ref=ccc  parent=bbb   idx=1
#     ChargePayment   root=aaa  ref=ddd  parent=bbb   idx=2
#     CreateOrder     root=aaa  ref=eee  parent=bbb   idx=3
#
# Fetch the entire execution tree:
#   root = OperationLog.find_by(operation_name: "ProcessCheckout", parent_reference_id: nil)
#   OperationLog.for_tree(root.root_reference_id)
#   # => 4 records, oldest-first, showing the full call tree
#
# Fetch direct children in call order:
#   OperationLog.children_of(root.reference_id)
#   # => [ValidateCart (idx:1), ChargePayment (idx:2), CreateOrder (idx:3)]
#
# Bare include Easyop::Flow (without inheriting ApplicationOperation) still works:
# steps show parent_operation_name and execution_index correctly,
# but the flow itself is not recorded.

# ── Plugin 3: Async ──────────────────────────────────────────────────────────

class Reports::GeneratePDF < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "reports"

  def call
    ctx.pdf = PdfGenerator.run(ctx.report_id)
  end
end

# Fluent form (preferred):
Reports::GeneratePDF.async.call(report_id: 123)
Reports::GeneratePDF.async(wait: 5.minutes).call(report_id: 123)
Reports::GeneratePDF.async(wait_until: Date.tomorrow.noon).call(report_id: 123)
Reports::GeneratePDF.async(queue: "low_priority").call(report_id: 123)

# Classic form (still works — no deprecation):
# Reports::GeneratePDF.call_async(report_id: 123)

# ActiveRecord objects are auto-serialized (class + id) and re-fetched in the job:
class Orders::SendConfirmation < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "mailer"
end

Orders::SendConfirmation.async.call(order: @order, user: current_user)
# => Serialized as: { "order" => { "__ar_class" => "Order", "__ar_id" => 42 },
#                     "user"  => { "__ar_class" => "User",  "__ar_id" => 7  } }

# The job class is created lazily on first enqueue:
Easyop::Plugins::Async::Job  # => the ActiveJob subclass

# queue DSL — declare the default queue on a class without re-declaring the plugin.
# Accepts Symbol or String. Inherited by subclasses; can be overridden at any level.
# Priority: per-call queue: argument > queue DSL > plugin queue: option > "default"
class Weather::BaseOperation < ApplicationOperation
  queue :weather
end

class Weather::FetchForecast < Weather::BaseOperation
  # inherits queue :weather automatically
  def call
    ctx.forecast = WeatherApi.fetch(ctx.location)
  end
end

class Weather::CleanupExpiredDays < Weather::BaseOperation
  queue :low_priority   # override just for this class

  def call
    WeatherRecord.where('recorded_at < ?', 30.days.ago).delete_all
  end
end

Weather::FetchForecast._async_default_queue      # => "weather"
Weather::CleanupExpiredDays._async_default_queue # => "low_priority"

# Per-call override still takes precedence:
Weather::CleanupExpiredDays.async(queue: "critical").call(attrs)

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

# ── Plugin 5: Events (producer) ──────────────────────────────────────────────

require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"

# Configure the bus once at boot (Memory is the default):
Easyop::Events::Registry.bus = :memory

# Declare events on any operation:
class PlaceOrder < ApplicationOperation
  plugin Easyop::Plugins::Events

  # Fire on success, include specific ctx keys as payload:
  emits "order.placed", on: :success, payload: [:order_id, :total]

  # Fire on failure, build payload with a Proc:
  emits "order.failed", on: :failure, payload: ->(ctx) { { error: ctx.error } }

  # Always fire (success or failure), full ctx as payload (default):
  emits "order.attempted", on: :always

  # Conditional: only fire when total exceeds threshold:
  emits "vip.order.placed", on: :success, guard: ->(ctx) { ctx.total > 1_000 }

  def call
    ctx.order_id = Order.create!(ctx.slice(:user_id, :items)).id
    ctx.total    = ctx.items.sum { |i| i[:price] }
  end
end

# The emitted Easyop::Events::Event carries:
#   event.name      # => "order.placed"
#   event.payload   # => { order_id: 42, total: 129.99 }
#   event.source    # => "PlaceOrder"
#   event.timestamp # => Time

# Subclasses inherit all emits declarations:
class PlaceSubscriptionOrder < PlaceOrder
  emits "subscription.placed", on: :success   # adds to the inherited set
end

# Per-class bus override (rare — use Registry for the global default):
class AuditOp < ApplicationOperation
  plugin Easyop::Plugins::Events, bus: Easyop::Events::Bus::Memory.new
  emits "audit.event", on: :always
end

# ── Plugin 6: EventHandlers (subscriber) ─────────────────────────────────────

require "easyop/plugins/event_handlers"

# Simple sync handler — receives ctx.event (Event object) + payload keys in ctx:
class SendOrderConfirmation < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "order.placed"   # exact pattern

  def call
    event    = ctx.event        # Easyop::Events::Event
    order_id = ctx.order_id     # from event.payload
    OrderMailer.confirm(order_id).deliver_later
  end
end

# One-segment wildcard — matches "order.placed", "order.failed", etc.:
class LogOrderEvent < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "order.*"

  def call
    Rails.logger.info "[order event] #{ctx.event.name}: #{ctx.event.payload}"
  end
end

# Any-depth wildcard — matches "warehouse.stock.low", "warehouse.alert.fire.east", etc.:
class WarehouseEventProcessor < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "warehouse.**"

  def call
    WarehouseAlert.process(ctx.event.name, ctx.event.payload)
  end
end

# Async handler (requires Plugins::Async also installed on the same class):
class IndexOrderAsync < ApplicationOperation
  plugin Easyop::Plugins::Async,         queue: "indexing"
  plugin Easyop::Plugins::EventHandlers

  on "order.*",      async: true             # enqueued via ActiveJob (internally uses call_async)
  on "inventory.**", async: true, queue: "low"  # per-subscription queue override

  def call
    # For async handlers, ctx.event_data is a plain Hash (serializable for ActiveJob)
    # and payload keys are also merged into ctx directly.
    SearchIndex.reindex(ctx.order_id)
  end
end

# Multiple on declarations (each registers its own subscription):
class MultiEventHandler < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "order.placed"
  on "order.updated"
  on "order.cancelled"

  def call
    AuditLog.record(event_name: ctx.event.name, payload: ctx.event.payload)
  end
end

# ── Events Bus configuration ──────────────────────────────────────────────────

# The bus must be configured BEFORE handler classes are loaded (class-load time
# is when `on` registers subscriptions with the bus).

# Option 1 — in-process Memory bus (default, no deps):
Easyop::Events::Registry.bus = :memory

# Option 2 — ActiveSupport::Notifications (requires ActiveSupport):
Easyop::Events::Registry.bus = :active_support

# Option 3 — custom subclass (see Bus::Adapter section below)
# Option 4 — duck-typed object (auto-wrapped in Bus::Custom):
class MinimalBus
  def publish(event) = Kafka.produce(topic: event.name, payload: event.to_h.to_json)
  def subscribe(pattern, &block) = Kafka.subscribe(pattern) { |msg| block.call(decode(msg)) }
end
Easyop::Events::Registry.bus = MinimalBus.new

# Option 5 — via configure block (applied when bus is first accessed):
Easyop.configure { |c| c.event_bus = :active_support }

# Test helpers — reset between examples:
Easyop::Events::Registry.reset!   # clears bus + subscriptions

# Memory-bus specific helpers:
bus = Easyop::Events::Registry.bus  # => Easyop::Events::Bus::Memory
bus.clear!                           # remove all subscriptions
bus.subscriber_count                 # => Integer

# ── Building a custom Bus (Bus::Adapter) ─────────────────────────────────────
#
# Subclass Easyop::Events::Bus::Adapter to build a transport-backed bus.
# It inherits glob helpers from Bus::Base and adds two production-grade utilities:
#
#   _safe_invoke(handler, event)   — calls handler, swallows StandardError
#   _compile_pattern(pattern)      — glob/string → memoized Regexp
#
# Both are protected — available in subclasses, not on the public interface.

require "easyop/events/bus/adapter"

# Example A — Decorator: wraps another bus and adds structured logging.
# No external gems required. Useful for debugging or audit trails.
class LoggingBus < Easyop::Events::Bus::Adapter
  def initialize(inner = Easyop::Events::Bus::Memory.new)
    super()
    @inner = inner
  end

  def publish(event)
    logger.info "[bus:publish] name=#{event.name} source=#{event.source} payload=#{event.payload}"
    @inner.publish(event)
  end

  def subscribe(pattern, &block)
    logger.debug "[bus:subscribe] pattern=#{pattern}"
    @inner.subscribe(pattern, &block)
  end

  def unsubscribe(handle)
    @inner.unsubscribe(handle)
  end

  private

  def logger
    defined?(Rails) ? Rails.logger : Logger.new($stdout)
  end
end

Easyop::Events::Registry.bus = LoggingBus.new
# Or wrap a specific inner bus:
Easyop::Events::Registry.bus = LoggingBus.new(Easyop::Events::Bus::ActiveSupportNotifications.new)

# Example B — Full RabbitMQ bus via the Bunny gem.
#
# Uses a topic exchange: AMQP routing-key patterns map directly to EasyOp globs.
#   EasyOp "*"  → AMQP "*"  (one segment — identical semantics)
#   EasyOp "**" → AMQP "#"  (zero-or-more segments)
#
#   Easyop::Events::Registry.bus = RabbitBus.new
#   Easyop::Events::Registry.bus = RabbitBus.new(ENV["AMQP_URL"])

require "bunny"
require "json"

class RabbitBus < Easyop::Events::Bus::Adapter
  EXCHANGE_NAME = "easyop.events"

  def initialize(amqp_url = ENV.fetch("AMQP_URL", "amqp://guest:guest@localhost"))
    super()
    @amqp_url = amqp_url
    @mutex    = Mutex.new
    @handles  = {}  # handle.object_id => { queue:, consumer: }
  end

  # Publish to the topic exchange; full event hash serialised as JSON.
  def publish(event)
    exchange.publish(
      event.to_h.merge(timestamp: event.timestamp.iso8601).to_json,
      routing_key:  event.name,
      content_type: "application/json",
      persistent:   false
    )
  end

  # Bind an exclusive, auto-delete queue and start consuming.
  # Returns an opaque handle suitable for #unsubscribe.
  def subscribe(pattern, &block)
    queue    = channel.queue("", exclusive: true, auto_delete: true)
    amqp_key = _to_amqp_pattern(pattern)
    queue.bind(exchange, routing_key: amqp_key)

    consumer = queue.subscribe(manual_ack: false) do |_delivery, _properties, body|
      data  = JSON.parse(body, symbolize_names: true)
      event = Easyop::Events::Event.new(
                name:      data[:name].to_s,
                payload:   data.fetch(:payload, {}),
                metadata:  data.fetch(:metadata, {}),
                source:    data[:source],
                timestamp: data[:timestamp] ? Time.parse(data[:timestamp].to_s) : Time.now
              )
      _safe_invoke(block, event)  # ← inherited from Bus::Adapter
    end

    handle = Object.new  # unique, opaque subscription token
    @mutex.synchronize { @handles[handle.object_id] = { queue: queue, consumer: consumer } }
    handle
  end

  # Cancel the consumer and delete the exclusive queue.
  def unsubscribe(handle)
    @mutex.synchronize do
      entry = @handles.delete(handle.object_id)
      return unless entry
      entry[:consumer].cancel
      entry[:queue].delete
    end
  end

  # Gracefully close the AMQP connection.
  # Call in an at_exit hook or a Rails initializer shutdown callback.
  def disconnect
    @mutex.synchronize do
      @connection&.close
      @connection = @channel = @exchange = nil
      @handles.clear
    end
  end

  private

  # EasyOp "**" → AMQP "#"; EasyOp "*" stays "*" (same one-segment semantics).
  def _to_amqp_pattern(pattern)
    return pattern.source if pattern.is_a?(Regexp)  # best-effort
    pattern.gsub("**", "#")
  end

  def connection
    @connection ||= Bunny.new(@amqp_url, recover_from_connection_close: true).tap(&:start)
  end

  def channel
    @channel ||= connection.create_channel
  end

  def exchange
    @exchange ||= channel.topic(EXCHANGE_NAME, durable: true)
  end
end

# Wire up and register a clean shutdown:
Easyop::Events::Registry.bus = RabbitBus.new
at_exit { Easyop::Events::Registry.bus.disconnect }

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

# ── Note (v0.5): Step-builder DSL and plugin Easyop::Plugins::Async ──────────
#
# The fluent step-builder methods (.async, .skip_if, .skip_unless, .on_exception,
# .tags, .wait) are class methods added by plugin Easyop::Plugins::Async.
#
# Rule: any operation class whose step-builder DSL is called inside a `flow`
# declaration MUST have `plugin Easyop::Plugins::Async` installed on it (or on a
# parent class it inherits from).
#
# An operation used as a BARE step (no modifiers) does NOT need the plugin.
#
# Examples:
#
#   # ✅ SendWelcomeEmail has the plugin — .async is a valid class method
#   class SendWelcomeEmail < ApplicationOperation
#     plugin Easyop::Plugins::Async
#     def call; ...; end
#   end
#
#   flow CreateUser,
#        SendWelcomeEmail.async,                            # OK — plugin installed
#        SendNudge.async(wait: 3.days)                     # OK — plugin installed
#                 .skip_if { |ctx| !ctx[:newsletter] },
#        RecordComplete                                     # OK — bare step, no plugin needed
#
#   # ❌ CreateUser has NO plugin — calling .async raises NoMethodError
#   class CreateUser < ApplicationOperation
#     def call; ...; end
#   end
#   CreateUser.async   # => NoMethodError: undefined method `async'
#
# The `.async` modifier routes the step to ActiveJob via `klass.call_async` in
# Mode-2 flows, or to the DB Scheduler in Mode-3 (durable) flows.
# The `.on_exception` and `.tags` modifiers are only meaningful in durable (Mode-3)
# flows; using them in a non-durable flow raises PersistentFlowOnlyOptionsError.
