#!/usr/bin/env ruby
# frozen_string_literal: true

# 09 — Fluent Async API & Chained Step DSL
#
# Covers:
#   Op.async.call(attrs)                  — replaces call_async (operation-level)
#   Op.async(wait: 5.minutes).call(attrs) — with scheduling delay
#   Op.skip_if { |ctx| ... }              — fluent step guard (inside flow)
#   Op.skip_unless { |ctx| ... }          — inverse guard
#   Op.on_exception(:reattempt!, ...)     — per-step exception policy (inside durable flow)
#   Op.on_exception(:cancel!)             — cancel durable flow on step failure
#   Op.wait(duration)                     — schedule delay without async
#   Op.tags(:tag)                         — scheduler tags (inside durable flow)
#   Chaining: Op.async(wait: 1.day).skip_if { ... }.on_exception(:cancel!)
#   Order-independence: skip_if.async == async.skip_if
#   Backward compat: call_async and bare class still work
#
# Run: ruby examples/code/09_fluent_async_api.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'
require 'easyop/plugins/async'

# ── Minimal ActiveJob stub (no Rails needed) ──────────────────────────────────

module ActiveJob
  class Base
    @@jobs = []

    def self.queue_as(_q); end

    def self.set(**opts)
      _make_proxy(opts)
    end

    def self._make_proxy(accumulated_opts)
      Class.new do
        define_singleton_method(:set) { |**more| ActiveJob::Base._make_proxy(accumulated_opts.merge(more)) }
        define_singleton_method(:perform_later) { |*args| ActiveJob::Base.jobs << { args: args, opts: accumulated_opts } }
      end
    end

    def self.jobs;       @@jobs;   end
    def self.clear_jobs!; @@jobs = []; end
  end
end

puts '─' * 60
puts '09 — Fluent Async API & Chained Step DSL'
puts '─' * 60

# ── Operation classes ─────────────────────────────────────────────────────────

class GenerateReport
  include Easyop::Operation
  plugin Easyop::Plugins::Async, queue: 'reports'

  def call
    ctx.report = "Report-#{ctx.report_id}"
    puts "  [GenerateReport] #{ctx.report}"
  end
end

class SendConfirmation
  include Easyop::Operation
  plugin Easyop::Plugins::Async, queue: 'mailer'

  def call
    puts "  [SendConfirmation] email sent to #{ctx.email}"
    ctx.confirmation_sent = true
  end
end

class SendFollowup
  include Easyop::Operation
  plugin Easyop::Plugins::Async, queue: 'mailer'

  def call
    puts "  [SendFollowup] followup sent to #{ctx.email}"
    ctx.followup_sent = true
  end
end

class NotifyBilling
  include Easyop::Operation
  plugin Easyop::Plugins::Async   # step-builder DSL (on_exception, tags) requires Async plugin

  def call
    puts "  [NotifyBilling] billing team notified for plan=#{ctx.plan}"
    ctx.billing_notified = true
  end
end

# ── 1. Operation-level: fluent .async.call replaces call_async ────────────────

puts "\n1. Op.async.call(attrs) — enqueue immediately"
ActiveJob::Base.clear_jobs!
GenerateReport.async.call(report_id: 42)
job = ActiveJob::Base.jobs.first
puts "  enqueued: #{!job.nil?}"
puts "  args:     #{job[:args].inspect}"
puts "  queue:    #{job[:opts][:queue]}"

puts "\n2. Op.async(wait: 300).call(attrs) — enqueue with delay"
ActiveJob::Base.clear_jobs!
GenerateReport.async(wait: 300).call(report_id: 99)
job = ActiveJob::Base.jobs.first
puts "  wait:     #{job[:opts][:wait]} seconds"

# ── 2. Equivalence with call_async ───────────────────────────────────────────

puts "\n3. Equivalence with call_async (backward compat)"
ActiveJob::Base.clear_jobs!
GenerateReport.call_async({ report_id: 1 }, wait: 60)
old_job = ActiveJob::Base.jobs.first[:opts]
ActiveJob::Base.clear_jobs!
GenerateReport.async(wait: 60).call(report_id: 1)
new_job = ActiveJob::Base.jobs.first[:opts]
puts "  call_async wait: #{old_job[:wait]} | fluent wait: #{new_job[:wait]}"
puts "  equivalent:      #{old_job[:wait] == new_job[:wait]}"

# ── 3. Fluent step DSL inside flow ────────────────────────────────────────────

puts "\n4. Fluent step DSL inside flow — skip_if"
order = []

class ValidateOrder
  include Easyop::Operation
  def call; ctx[:order_valid] = true; end
end

class ApplyCoupon
  include Easyop::Operation
  plugin Easyop::Plugins::Async

  def call
    puts "  [ApplyCoupon] applied"
    ctx[:discount] = 0.2
  end
end

class CompleteOrder
  include Easyop::Operation
  def call; ctx[:completed] = true; end
end

class OrderFlow
  include Easyop::Flow

  flow ValidateOrder,
       ApplyCoupon.skip_if { |ctx| !ctx[:has_coupon] },   # fluent skip_if
       CompleteOrder
end

puts "\n  With coupon:"
r = OrderFlow.call(has_coupon: true)
puts "  discount: #{r[:discount].inspect}"

puts "\n  Without coupon (step skipped):"
r = OrderFlow.call(has_coupon: false)
puts "  discount: #{r[:discount].inspect}"   # nil — step skipped

# ── 4. skip_unless ───────────────────────────────────────────────────────────

puts "\n5. skip_unless — run only when block returns truthy"

class SendSms
  include Easyop::Operation
  plugin Easyop::Plugins::Async

  def call
    puts "  [SendSms] SMS sent"
    ctx[:sms_sent] = true
  end
end

class NotifyFlow
  include Easyop::Flow
  flow SendSms.skip_unless { |ctx| ctx[:sms_enabled] }
end

r = NotifyFlow.call(sms_enabled: true)
puts "  sms_enabled: true  → sms_sent: #{r[:sms_sent].inspect}"

r = NotifyFlow.call(sms_enabled: false)
puts "  sms_enabled: false → sms_sent: #{r[:sms_sent].inspect}"

# ── 5. on_exception (no Async plugin needed) ──────────────────────────────────

puts "\n6. on_exception — durable-flow step builder, no Async plugin needed"

step = NotifyBilling.on_exception(:reattempt!, max_reattempts: 3)
puts "  on_exception: #{step.opts[:on_exception].inspect}"
puts "  max_reattempts: #{step.opts[:max_reattempts]}"

step2 = NotifyBilling.on_exception(:reattempt!, max_reattempts: 5)
puts "  cancel policy: #{NotifyBilling.on_exception(:cancel!).opts[:on_exception].inspect}"
puts "  reattempt max_reattempts: #{step2.opts[:max_reattempts]}"

# ── 6. Chaining is order-independent ─────────────────────────────────────────

puts "\n7. Order-independence: skip_if.async == async.skip_if"

guard = ->(ctx) { ctx[:skip] }
b1 = SendConfirmation.skip_if { |ctx| ctx[:skip] }.async(wait: 30)
b2 = SendConfirmation.async(wait: 30).skip_if { |ctx| ctx[:skip] }

puts "  b1.opts[:async]: #{b1.opts[:async]} | b2.opts[:async]: #{b2.opts[:async]}"
puts "  b1.opts[:wait]:  #{b1.opts[:wait]}  | b2.opts[:wait]:  #{b2.opts[:wait]}"
puts "  both have skip_if: #{b1.opts.key?(:skip_if) && b2.opts.key?(:skip_if)}"
puts "  equal:           #{b1.opts.except(:skip_if) == b2.opts.except(:skip_if)}"

# ── 7. Full chain example ─────────────────────────────────────────────────────

puts "\n8. Full chained step — .async.skip_if.on_exception.tags"

full_step = SendFollowup
  .async(wait: 86_400)                                # 1 day
  .skip_if { |ctx| ctx[:opted_out] }
  .on_exception(:reattempt!, max_reattempts: 3)
  .tags(:email, :engagement)

puts "  async?:         #{full_step.opts[:async] == true}"
puts "  wait:           #{full_step.opts[:wait]}"
puts "  has skip_if:    #{full_step.opts.key?(:skip_if)}"
puts "  on_exception:   #{full_step.opts[:on_exception].inspect}"
puts "  max_reattempts: #{full_step.opts[:max_reattempts]}"
puts "  tags:           #{full_step.opts[:tags].inspect}"
puts "  klass:          #{full_step.klass}"

# ── 8. Immutability — builders are frozen, reuse is safe ─────────────────────

puts "\n9. Immutability — shared builder, independent chains"

base_builder = SendConfirmation.async(wait: 60)
step_a = base_builder.skip_if { |ctx| ctx[:a] }
step_b = base_builder.skip_if { |ctx| ctx[:b] }

puts "  base_builder untouched: #{!base_builder.opts.key?(:skip_if)}"
puts "  step_a and step_b are independent: #{step_a.object_id != step_b.object_id}"

# ── 9. PersistentFlowOnlyOptionsError on .call with guards ───────────────────

puts "\n10. PersistentFlowOnlyOptionsError — durable-only options cannot be used with .call directly"

begin
  SendConfirmation.skip_if { true }.call(email: 'x@y.com')
rescue Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError => e
  puts "  Caught: #{e.class.name.split('::').last}"
  puts "  Message: #{e.message}"
end

# ── 10. Backward compatibility ────────────────────────────────────────────────

puts "\n11. Backward compat — call_async and bare class still work; fluent DSL replaces array form"

class BackCompatFlow
  include Easyop::Flow

  flow ValidateOrder,                                                # bare class
       ApplyCoupon.skip_if { |ctx| !ctx[:has_coupon] },            # fluent DSL (replaces old array form)
       CompleteOrder                                                 # bare class
end

r = BackCompatFlow.call(has_coupon: false)
puts "  discount (skipped): #{r[:discount].inspect}"               # nil

r = BackCompatFlow.call(has_coupon: true)
puts "  discount (applied): #{r[:discount].inspect}"               # 0.2

ActiveJob::Base.clear_jobs!
GenerateReport.call_async({ report_id: 77 }, wait: 10)
puts "  call_async still works: #{!ActiveJob::Base.jobs.empty?}"

puts "\n✓ All fluent API demonstrations complete"
