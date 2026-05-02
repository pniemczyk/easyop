#!/usr/bin/env ruby
# frozen_string_literal: true

# EasyOp usage examples — runnable standalone
# Run with: ruby examples/usage.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "easyop"
require "json"

puts "=" * 60
puts "EasyOp Usage Examples"
puts "=" * 60

# ── 1. Basic operation ─────────────────────────────────────────────────────────

class DoubleNumber
  include Easyop::Operation

  def call
    ctx.fail!(error: "input must be a number") unless ctx.number.is_a?(Numeric)
    ctx.result = ctx.number * 2
  end
end

puts "\n1. Basic operation"
result = DoubleNumber.call(number: 21)
puts "  success? #{result.success?}"
puts "  result:  #{result.result}"   # => 42

result = DoubleNumber.call(number: "oops")
puts "  failure? #{result.failure?}"
puts "  error:   #{result.error}"

# ── 2. Hooks ──────────────────────────────────────────────────────────────────

class NormalizeEmail
  include Easyop::Operation

  before :strip_whitespace
  after  :log_result

  def call
    ctx.normalized = ctx.email.downcase
  end

  private

  def strip_whitespace
    ctx.email = ctx.email.to_s.strip
  end

  def log_result
    puts "  [log] normalized to: #{ctx.normalized}" if ctx.success?
  end
end

puts "\n2. Hooks (before / after)"
result = NormalizeEmail.call(email: "  Alice@Example.COM  ")
puts "  normalized: #{result.normalized}"

# ── 3. rescue_from ────────────────────────────────────────────────────────────

class ParseJson
  include Easyop::Operation

  rescue_from JSON::ParserError do |e|
    ctx.fail!(error: "Invalid JSON: #{e.message.lines.first.strip}")
  end

  def call
    ctx.parsed = JSON.parse(ctx.raw)
  end
end

puts "\n3. rescue_from"
result = ParseJson.call(raw: '{"name": "Alice"}')
puts "  parsed: #{result.parsed}"

result = ParseJson.call(raw: "not { json }")
puts "  failure: #{result.failure?}"
puts "  error:   #{result.error[0, 40]}..."

# ── 4. Typed params schema ────────────────────────────────────────────────────

class RegisterUser
  include Easyop::Operation

  params do
    required :email,    String
    required :age,      Integer
    optional :plan,     String, default: "free"
    optional :admin,    :boolean, default: false
  end

  def call
    ctx.user_id = "usr_#{ctx.email.hash.abs}"
  end
end

puts "\n4. Typed params schema"
result = RegisterUser.call(email: "alice@example.com", age: 30)
puts "  user_id: #{result.user_id}"
puts "  plan:    #{result.plan}"    # default applied
puts "  admin:   #{result.admin}"   # default applied

result = RegisterUser.call(email: "bob@example.com")
puts "  missing age → failure? #{result.failure?}"
puts "  error: #{result.error}"

# ── 5. ctx.fail! with errors hash ────────────────────────────────────────────

class ValidateOrder
  include Easyop::Operation

  def call
    errs = {}
    errs[:quantity] = "must be positive" if ctx.quantity.to_i <= 0
    errs[:item]     = "is required"      if ctx.item.to_s.empty?

    ctx.fail!(error: "Validation failed", errors: errs) if errs.any?
    ctx.total = ctx.quantity * ctx.unit_price
  end
end

puts "\n5. ctx.fail! with errors hash"
result = ValidateOrder.call(quantity: -1, item: "", unit_price: 10)
puts "  errors: #{result.errors}"

result = ValidateOrder.call(quantity: 3, item: "Widget", unit_price: 5)
puts "  total:  #{result.total}"

# ── 6. Chainable result callbacks ─────────────────────────────────────────────

puts "\n6. Chainable on_success / on_failure"

DoubleNumber.call(number: 7)
  .on_success { |ctx| puts "  Success! result = #{ctx.result}" }
  .on_failure { |ctx| puts "  Failed: #{ctx.error}" }

DoubleNumber.call(number: "bad")
  .on_success { |ctx| puts "  Success! result = #{ctx.result}" }
  .on_failure { |ctx| puts "  Failed: #{ctx.error}" }

# ── 7. Pattern matching (Ruby 3+) ─────────────────────────────────────────────

puts "\n7. Pattern matching"
result = DoubleNumber.call(number: 5)
verdict = case result
          in { success: true, result: Integer => n } then "doubled to #{n}"
          in { success: false, error: String => e }  then "error: #{e}"
          end
puts "  #{verdict}"

# ── 8. Flow ───────────────────────────────────────────────────────────────────

class FetchNumber
  include Easyop::Operation
  def call
    ctx.number = ctx.raw_input.to_i
    ctx.fail!(error: "Not a valid number") if ctx.number == 0 && ctx.raw_input != "0"
  end
end

class SquareIt
  include Easyop::Operation
  def call
    ctx.squared = ctx.number ** 2
  end
end

class FormatResult
  include Easyop::Operation
  def call
    ctx.output = "#{ctx.number}^2 = #{ctx.squared}"
  end
end

class ComputeSquare
  include Easyop::Flow
  flow FetchNumber, SquareIt, FormatResult
end

puts "\n8. Flow composition"
result = ComputeSquare.call(raw_input: "7")
puts "  #{result.output}"

result = ComputeSquare.call(raw_input: "abc")
puts "  failure: #{result[:error]}"

# ── 9. around hook with timing ────────────────────────────────────────────────

class SlowOperation
  include Easyop::Operation

  around do |inner|
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    inner.call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    puts "  [timing] took #{(elapsed * 1000).round(2)}ms"
  end

  def call
    ctx.result = (1..1000).sum
  end
end

puts "\n9. Around hook (timing)"
SlowOperation.call

# ── 10. Inheritance — ApplicationOperation base ────────────────────────────────

class ApplicationOperation
  include Easyop::Operation

  rescue_from StandardError do |e|
    puts "  [ApplicationOperation] caught: #{e.class}: #{e.message}"
    ctx.fail!(error: "An error occurred")
  end
end

class RiskyOp < ApplicationOperation
  def call
    raise "Something exploded"
  end
end

puts "\n10. Inheritance with shared rescue_from"
result = RiskyOp.call
puts "  failure: #{result.failure?}"
puts "  error:   #{result.error}"

# ── 11. skip_if — optional steps in a flow ────────────────────────────────────

class ApplyCoupon
  include Easyop::Operation

  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    ctx.discount = ctx.coupon_code == "SAVE10" ? 10 : 5
  end
end

class ComputeTotal
  include Easyop::Operation
  def call
    ctx.total = 100 - (ctx[:discount] || 0)
  end
end

class CheckoutFlow
  include Easyop::Flow
  flow ApplyCoupon, ComputeTotal
end

puts "\n11. skip_if — optional steps"
result = CheckoutFlow.call(coupon_code: "SAVE10")
puts "  with coupon  → discount=#{result.discount}, total=#{result.total}"

result = CheckoutFlow.call
puts "  without coupon → discount=#{result[:discount].inspect}, total=#{result.total}"

# ── 12. prepare — pre-registered callbacks ────────────────────────────────

puts "\n12. prepare (pre-registered callbacks)"

# Block-style callbacks registered before .call
CheckoutFlow.prepare
  .on_success { |ctx| puts "  [builder] success! total=#{ctx.total}" }
  .on_failure { |ctx| puts "  [builder] failed: #{ctx.error}" }
  .call(coupon_code: "SAVE10")

# Symbol-style callbacks via bind_with
target = Object.new
target.define_singleton_method(:checkout_ok)   { |ctx| puts "  [bound] order total=#{ctx.total}" }
target.define_singleton_method(:checkout_fail) { |ctx| puts "  [bound] error=#{ctx.error}" }

CheckoutFlow.prepare
  .bind_with(target)
  .on(success: :checkout_ok, fail: :checkout_fail)
  .call(coupon_code: "SAVE10")

# ctx.slice
puts "\n13. ctx.slice"
result = CheckoutFlow.call(coupon_code: "SAVE10")
puts "  slice: #{result.slice(:discount, :total)}"

# ── 14. Domain events — emitting (Plugins::Events) ────────────────────────────

require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"

# Use the in-process memory bus (default — no external deps)
Easyop::Events::Registry.bus = :memory

# Manually subscribe to capture events for inspection
fired_events = []
Easyop::Events::Registry.bus.subscribe("ticket.*") { |e| fired_events << e }

class IssueTicket
  include Easyop::Operation
  plugin Easyop::Plugins::Events

  emits "ticket.issued",       on: :success, payload: [:ticket_id, :seat]
  emits "ticket.issue_failed", on: :failure, payload: ->(ctx) { { reason: ctx.error } }
  emits "ticket.attempt",      on: :always

  def call
    ctx.fail!(error: "no_seats") if ctx.available.to_i.zero?
    ctx.ticket_id = "#{ctx.seat.upcase}-001"
  end
end

puts "\n14. Domain events — emitting (Plugins::Events)"
r = IssueTicket.call(seat: "a1", available: 5)
puts "  success? #{r.success?}  ticket_id=#{r.ticket_id}"
puts "  events fired: #{fired_events.map(&:name).inspect}"
# => ["ticket.issued", "ticket.attempt"]
puts "  ticket.issued payload: #{fired_events.first.payload.inspect}"

fired_events.clear
r = IssueTicket.call(seat: "a1", available: 0)
puts "  failure? #{r.failure?}  error=#{r.error}"
puts "  events fired: #{fired_events.map(&:name).inspect}"
# => ["ticket.issue_failed", "ticket.attempt"]

# ── 15. Domain events — handling (Plugins::EventHandlers) ─────────────────────

require "easyop/plugins/event_handlers"

# Reset: gives a clean bus so NotifyCustomer's subscription is the only one.
Easyop::Events::Registry.reset!

class NotifyCustomer
  include Easyop::Operation
  plugin Easyop::Plugins::EventHandlers

  @log = []
  class << self; attr_reader :log; end

  on "ticket.issued"        # exact pattern
  on "ticket.issue_failed"  # exact pattern

  def call
    # ctx.event      → Easyop::Events::Event object
    # ctx[:ticket_id] → use hash-style for optional payload keys (not all events carry ticket_id)
    self.class.log << "#{ctx.event.name}:#{ctx[:ticket_id] || 'n/a'}"
    puts "  [handler] #{ctx.event.name}  ticket_id=#{ctx[:ticket_id] || 'n/a'}"
  end
end

puts "\n15. Domain events — handling (Plugins::EventHandlers)"
IssueTicket.call(seat: "b2", available: 3)  # fires ticket.issued + ticket.attempt
IssueTicket.call(seat: "b2", available: 0)  # fires ticket.issue_failed + ticket.attempt
puts "  handler log: #{NotifyCustomer.log.inspect}"

# ── 16. Custom bus via Bus::Adapter ────────────────────────────────────────────

require "easyop/events/bus/adapter"

# Decorator: wraps Memory and adds per-publish logging to stdout
class VerboseBus < Easyop::Events::Bus::Adapter
  attr_reader :publish_log

  def initialize
    super
    @inner       = Easyop::Events::Bus::Memory.new
    @publish_log = []
  end

  def publish(event)
    entry = "#{event.name} → #{event.payload}"
    @publish_log << entry
    puts "  [VerboseBus] #{entry}"
    @inner.publish(event)
  end

  def subscribe(pattern, &block) = @inner.subscribe(pattern, &block)
  def unsubscribe(handle)        = @inner.unsubscribe(handle)
end

puts "\n16. Custom bus via Bus::Adapter (LoggingBus decorator)"
verbose = VerboseBus.new
Easyop::Events::Registry.bus = verbose
Easyop::Events::Registry.bus.subscribe("ticket.*") { |e| puts "  [listener] received #{e.name}" }

IssueTicket.call(seat: "c3", available: 2)
puts "  VerboseBus publish_log: #{verbose.publish_log.inspect}"

Easyop::Events::Registry.reset!

puts "\n" + "=" * 60
puts "§17-19 — v0.5 Unified Flow API (Mode 1/2/3)"
puts "=" * 60

# ── §17. Mode 2 — fire-and-forget async ───────────────────────────────────────
# Requires easyop/plugins/async and a minimal ActiveJob stub.
# No `subject` declared — returns Ctx; async step enqueued via call_async.

require "easyop/plugins/async"

module ActiveJob
  class Base
    @@jobs = []
    def self.queue_as(_q); end
    def self.set(**opts) = Class.new { define_singleton_method(:perform_later) { |*a| ActiveJob::Base.jobs << { args: a, opts: opts } } }
    def self.jobs;       @@jobs;   end
    def self.clear_jobs!; @@jobs = []; end
  end
end

class PrepareShipment
  include Easyop::Operation
  def call
    ctx.shipment_id = "SHP-#{ctx[:order_id]}-#{rand(1000)}"
    puts "  [PrepareShipment] created #{ctx.shipment_id}"
  end
end

class SendShipmentNotification
  include Easyop::Operation
  plugin Easyop::Plugins::Async, queue: "notifications"

  def call
    puts "  [SendShipmentNotification] email sent (should not print — step is async)"
    ctx.notification_sent = true
  end
end

class FulfillOrder
  include Easyop::Flow

  flow PrepareShipment,
       SendShipmentNotification.async   # Mode 2: enqueued via call_async
end

puts "\n17. Mode 2 — fire-and-forget async"
ActiveJob::Base.clear_jobs!
result = FulfillOrder.call(order_id: 42)

puts "  returns Ctx:           #{result.is_a?(Easyop::Ctx)}"
puts "  PrepareShipment ran:   #{!result[:shipment_id].nil?}"
puts "  notification_sent:     #{result[:notification_sent].inspect}"  # nil — step enqueued, not run
puts "  enqueued jobs:         #{ActiveJob::Base.jobs.size}"           # 1
puts "  job class:             #{ActiveJob::Base.jobs.first[:args][0]}"

# ── §18. Mode 3 — durable suspend/resume via DB ──────────────────────────────
# Requires easyop/persistent_flow + easyop/scheduler and in-memory stubs.
# `subject :order` is the ONLY durability trigger.

require "easyop/persistent_flow"
require "easyop/scheduler"

# --- In-memory AR stubs (no database needed) ---

class FakeScope
  include Enumerable
  def initialize(records) = @records = records
  def each(&blk)          = @records.each(&blk)
  def first               = @records.first
  def exists?             = @records.any?
  def count               = @records.size
  def where(*_a, **cond)
    return self if _a.any? && cond.empty?
    FakeScope.new(@records.select { |r| cond.all? { |k, v| r.respond_to?(k) && r.public_send(k) == v } })
  end
  def update_all(**attrs)
    @records.each { |r| attrs.each { |k, v| r.public_send(:"#{k}=", v) if r.respond_to?(:"#{k}=") } }
    @records.size
  end
end

module ActiveRecord; class Base; end; end unless defined?(ActiveRecord)

class FakeOrder < ActiveRecord::Base   # inherit so is_a?(AR::Base) → true for Serializer
  attr_accessor :id, :email, :status
  @@store = {}
  def self.store = @@store
  def self.reset! = (@@store = {})
  def self.find(id) = @@store.fetch(id.to_i) { raise "FakeOrder #{id} not found" }
  def self.create!(attrs)
    id = (@@store.keys.max || 0) + 1
    o  = new; attrs.each { |k, v| o.public_send(:"#{k}=", v) }; o.id = id
    @@store[id] = o; o
  end
  def initialize; @status = 'pending'; end
end

class FakeDurableRun
  include Easyop::PersistentFlow::FlowRunModel
  attr_accessor :id, :flow_class, :context_data, :status, :current_step_index,
                :subject_type, :subject_id, :started_at, :finished_at
  @@store = []; @@ctr = 0
  def self.store  = @@store
  def self.reset! = (@@store = []; @@ctr = 0)
  def self.create!(attrs)
    obj = new; attrs.each { |k, v| obj.public_send(:"#{k}=", v) }
    @@ctr += 1; obj.id = @@ctr; @@store << obj; obj
  end
  def self.find(id) = @@store.find { |r| r.id == id.to_i } || raise("FakeDurableRun #{id} not found")
  def self.where(*a, **c) = a.any? && c.empty? ? FakeScope.new(@@store) : FakeScope.new(@@store.select { |r| c.all? { |k, v| r.respond_to?(k) && r.public_send(k) == v } })
  def initialize; @status = 'pending'; @current_step_index = 0; @context_data = '{}'; end
  def update_columns(a) = a.each { |k, v| public_send(:"#{k}=", v) } && self
  def reload = self
end

class FakeDurableStep
  include Easyop::PersistentFlow::FlowRunStepModel
  attr_accessor :id, :flow_run_id, :step_index, :operation_class, :status,
                :attempt, :error_class, :error_message, :started_at, :finished_at
  @@store = []; @@ctr = 0
  def self.store  = @@store
  def self.reset! = (@@store = []; @@ctr = 0)
  def self.create!(attrs)
    obj = new; attrs.each { |k, v| obj.public_send(:"#{k}=", v) }
    @@ctr += 1; obj.id = @@ctr; @@store << obj; obj
  end
  def self.where(*a, **c) = a.any? && c.empty? ? FakeScope.new(@@store) : FakeScope.new(@@store.select { |r| c.all? { |k, v| r.respond_to?(k) && r.public_send(k) == v } })
  def initialize; @status = 'running'; @attempt = 0; end
  def update_columns(a) = a.each { |k, v| public_send(:"#{k}=", v) } && self
end

class FakeTask
  attr_accessor :id, :operation_class, :ctx_data, :run_at, :tags, :state
  @@store = []; @@ctr = 0
  def self.store  = @@store
  def self.reset! = (@@store = []; @@ctr = 0)
  def self.connection = Struct.new(:adapter_name).new('fake_adapter')
  def self.create!(attrs)
    obj = new; attrs.each { |k, v| obj.public_send(:"#{k}=", v) if obj.respond_to?(:"#{k}=") }
    @@ctr += 1; obj.id ||= @@ctr; obj.state ||= 'scheduled'; @@store << obj; obj
  end
  def self.where(*a, **c) = a.any? && c.empty? ? FakeScope.new(@@store) : FakeScope.new(@@store.select { |r| c.respond_to?(:all?) && c.all? { |k, v| r.respond_to?(k) && r.public_send(k) == v } })
  def initialize; @state = 'scheduled'; end
  def update_columns(a) = a.each { |k, v| public_send(:"#{k}=", v) if respond_to?(:"#{k}=") } && self
end

unless ''.respond_to?(:constantize)
  class String; def constantize; Object.const_get(self); end; end
end
unless Time.respond_to?(:current)
  class Time; def self.current; now; end; end
end

Easyop.configure do |c|
  c.persistent_flow_model      = 'FakeDurableRun'
  c.persistent_flow_step_model = 'FakeDurableStep'
  c.scheduler_model            = 'FakeTask'
end

# Speedrun helper — drives pending scheduled tasks synchronously (test helper)
def speedrun_durable(flow_run, max: 20)
  max.times do
    break if flow_run.terminal?
    task = FakeTask.store.find { |t|
      t.state == 'scheduled' &&
        Easyop::Scheduler::Serializer.deserialize(t.ctx_data)[:flow_run_id] == flow_run.id
    }
    break unless task
    task.state = 'running'
    Easyop::PersistentFlow::Runner.execute_scheduled_step!(flow_run)
  end
  flow_run.reload
end

class ValidateOrder
  include Easyop::Operation
  def call
    ctx.fail!(error: "invalid order") unless ctx[:order]&.status == 'pending'
    puts "  [ValidateOrder] order #{ctx.order.id} validated"
  end
end

class ChargeOrder
  include Easyop::Operation
  def call
    ctx.order.status = 'paid'
    puts "  [ChargeOrder] order #{ctx.order.id} charged"
    ctx.payment_id = "PAY-#{rand(9999)}"
  end
end

class ConfirmOrder
  include Easyop::Operation
  def call
    ctx.order.status = 'confirmed'
    puts "  [ConfirmOrder] order #{ctx.order.id} confirmed"
  end
end

class DurableOrderFlow
  include Easyop::Flow
  subject :order   # Mode 3 — returns FlowRun; ctx persisted across async boundaries

  flow ValidateOrder, ChargeOrder, ConfirmOrder
end

puts "\n18. Mode 3 — durable flow with subject"
FakeDurableRun.reset!; FakeDurableStep.reset!; FakeTask.reset!; FakeOrder.reset!

order = FakeOrder.create!(email: "buyer@example.com", status: "pending")
flow_run = DurableOrderFlow.call(order: order)

puts "  returns FlowRun:  #{flow_run.is_a?(FakeDurableRun)}"
puts "  status:           #{flow_run.status}"       # succeeded
puts "  subject_type:     #{flow_run.subject_type}" # FakeOrder
puts "  subject_id:       #{flow_run.subject_id}"   # 1
puts "  order status:     #{order.status}"           # confirmed

# ── §19. Free composition — outer plain + inner durable → auto-promoted ────────

class InnerDurableOrder
  include Easyop::Flow
  subject :order
  flow ValidateOrder, ChargeOrder
end

class AuditStep
  include Easyop::Operation
  def call
    puts "  [AuditStep] auditing"
    ctx.audit_done = true
  end
end

class OuterPlainFlow
  include Easyop::Flow
  flow AuditStep, InnerDurableOrder   # no subject — but inner has one
end

puts "\n19. Free composition — outer plain embeds durable inner → auto-promoted"
FakeDurableRun.reset!; FakeDurableStep.reset!; FakeTask.reset!; FakeOrder.reset!

order2 = FakeOrder.create!(email: "buyer2@example.com", status: "pending")
result19 = OuterPlainFlow.call(order: order2)

puts "  returns FlowRun:  #{result19.is_a?(FakeDurableRun)}"   # true — outer auto-promoted
puts "  flow_class:       #{result19.flow_class}"               # OuterPlainFlow
puts "  status:           #{result19.status}"                    # succeeded
puts "  subject_type:     #{result19.subject_type}"              # FakeOrder

puts "\n" + "=" * 60
puts "All examples complete."
