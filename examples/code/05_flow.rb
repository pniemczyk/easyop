#!/usr/bin/env ruby
# frozen_string_literal: true

# 05 — Flow Composition
#
# Covers:
#   include Easyop::Flow
#   flow Step1, Step2, Step3
#   Lambda guard before a step: ->(ctx) { condition }
#   skip_if on a step class
#   rollback — runs in reverse on failure
#   prepare + FlowBuilder callbacks
#
# Run: ruby examples/code/05_flow.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'

puts '─' * 50
puts '05 — Flow Composition'
puts '─' * 50

# ── Basic flow — three sequential steps ───────────────────────────────────────

class ParseInput
  include Easyop::Operation

  def call
    ctx.fail!(error: "input must be a positive number") unless ctx.raw.to_s.match?(/\A\d+\z/)
    ctx.number = ctx.raw.to_i
  end
end

class DoubleIt
  include Easyop::Operation

  def call
    ctx.doubled = ctx.number * 2
  end
end

class FormatOutput
  include Easyop::Operation

  def call
    ctx.output = "#{ctx.number} × 2 = #{ctx.doubled}"
  end
end

class DoubleFlow
  include Easyop::Flow
  flow ParseInput, DoubleIt, FormatOutput
end

puts "\nBasic flow — success"
r = DoubleFlow.call(raw: '7')
puts "  #{r.output}"                         # 7 × 2 = 14

puts "\nBasic flow — failure (stops chain)"
r = DoubleFlow.call(raw: 'abc')
puts "  failure? #{r.failure?}"
puts "  error:   #{r.error}"

# ── Lambda guard — conditional step ──────────────────────────────────────────

class ApplyCoupon
  include Easyop::Operation

  def call
    ctx.discount = ctx.coupon_code == 'HALF' ? 0.50 : 0.10
    ctx.total    = ctx.price * (1 - ctx.discount)
    puts "  [ApplyCoupon] discount=#{(ctx.discount * 100).to_i}%"
  end
end

class CalculateTotal
  include Easyop::Operation

  def call
    ctx[:total] ||= ctx[:price]   # no coupon → full price
  end
end

class CheckoutFlow
  include Easyop::Flow

  flow ->(ctx) { ctx[:coupon_code] }, ApplyCoupon,   # guard before ApplyCoupon
       CalculateTotal
end

puts "\nLambda guard — with coupon"
r = CheckoutFlow.call(price: 100.0, coupon_code: 'HALF')
puts "  total: #{r.total}"                   # 50.0

puts "\nLambda guard — without coupon"
r = CheckoutFlow.call(price: 100.0)
puts "  total: #{r.total}"                   # 100.0

# ── skip_if on the step class ─────────────────────────────────────────────────

class SendSmsAlert
  include Easyop::Operation

  skip_if { |ctx| !ctx[:sms_enabled] }

  def call
    puts "  [SendSmsAlert] SMS sent to #{ctx.phone}"
    ctx.sms_sent = true
  end
end

class NotifyUser
  include Easyop::Flow
  flow SendSmsAlert
end

puts "\nskip_if — sms_enabled: true"
r = NotifyUser.call(sms_enabled: true, phone: '+1-555-0100')
puts "  sms_sent: #{r.sms_sent}"

puts "\nskip_if — sms_enabled: false (step skipped)"
r = NotifyUser.call(sms_enabled: false, phone: '+1-555-0100')
puts "  sms_sent: #{r[:sms_sent].inspect}"   # nil — step never ran

# ── rollback — runs in reverse on failure ────────────────────────────────────

class ReserveInventory
  include Easyop::Operation

  def call
    puts "  [ReserveInventory] reserving #{ctx.qty} units"
    ctx.inventory_reserved = true
  end

  def rollback
    puts "  [ReserveInventory] rollback — releasing #{ctx.qty} units"
    ctx.inventory_reserved = false
  end
end

class ChargeCard
  include Easyop::Operation

  def call
    ctx.fail!(error: "card declined") if ctx.card == 'bad'
    puts "  [ChargeCard] charged #{ctx.amount}"
    ctx.charged = true
  end

  def rollback
    puts "  [ChargeCard] rollback — refunding #{ctx.amount}"
    ctx.charged = false
  end
end

class PlaceOrder
  include Easyop::Flow
  flow ReserveInventory, ChargeCard
end

puts "\nrollback — failure reverses completed steps"
r = PlaceOrder.call(qty: 2, amount: 99.0, card: 'bad')
puts "  failure? #{r.failure?}"
puts "  inventory_reserved after rollback: #{r.inventory_reserved}"

# ── Free composition — embed a flow inside a flow ─────────────────────────────

class ApplyTax
  include Easyop::Operation

  def call
    ctx.tax   = ctx.number * 0.1
    ctx.total = ctx.doubled + ctx.tax
    ctx.output = "#{ctx.number} × 2 + 10% tax = #{ctx.total.round(2)}"
  end
end

class DoubleWithTax
  include Easyop::Flow
  flow DoubleFlow,   # embed the existing three-step flow
       ApplyTax      # add a tax step on top — ctx.number, ctx.doubled available
end

puts "\nFree composition — embedded flow shares ctx"
r = DoubleWithTax.call(raw: '5')
puts "  #{r.output}"   # 5 × 2 + 10% tax = 10.5

# ── See also ──────────────────────────────────────────────────────────────────
# 08_durable_workflow.rb — Scenario 7: outer plain flow embeds a durable inner
#   (inner's `subject` auto-promotes outer; .call returns FlowRun instead of Ctx)
# 08_durable_workflow.rb — Scenario 8: chained .async(wait: N) steps with subject
#   (the canonical "durable wait chain" pattern; steps run hours/days apart)
