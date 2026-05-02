#!/usr/bin/env ruby
# frozen_string_literal: true

# 06 — Events Plugin
#
# Covers:
#   Plugins::Events — emit domain events from an operation
#   emits declaration: event name, :on trigger, payload lambda or keys array
#   Plugins::EventHandlers — subscribe an operation to incoming events
#   on "pattern" glob matching
#   capture_events helper for testing
#   Custom bus (in-process memory bus default)
#
# Run: ruby examples/code/06_events.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/memory'
require 'easyop/events/registry'
require 'easyop/plugins/events'
require 'easyop/plugins/event_handlers'

Easyop::Events::Registry.bus = :memory

puts '─' * 50
puts '06 — Events Plugin'
puts '─' * 50

# ── Emitting events from an operation ─────────────────────────────────────────

class ProcessPayment
  include Easyop::Operation
  plugin Easyop::Plugins::Events

  # on: :success  → only emits when the operation succeeds
  # payload: lambda receives ctx
  emits 'payment.charged', on: :success,
        payload: ->(ctx) { { order_id: ctx.order_id, amount: ctx.amount } }

  # on: :failure  → only emits when the operation fails
  emits 'payment.failed', on: :failure,
        payload: ->(ctx) { { order_id: ctx.order_id, reason: ctx.error } }

  # on: :always   → emits regardless of outcome (audit trail)
  emits 'payment.attempted', on: :always,
        payload: [:order_id]   # array form — picks keys directly from ctx

  def call
    ctx.fail!(error: 'card declined') if ctx.card == 'bad'
    ctx.charge_id = "ch_#{ctx.order_id}_ok"
  end
end

# Capture emitted events manually for inspection
captured = []
Easyop::Events::Registry.bus.subscribe('payment.*') { |e| captured << e }

puts "\nSuccess path"
ProcessPayment.call(order_id: 101, amount: 49.95, card: '4111')
puts "  events: #{captured.map(&:name).inspect}"
puts "  payment.charged payload: #{captured.find { |e| e.name == 'payment.charged' }.payload}"

captured.clear

puts "\nFailure path"
ProcessPayment.call(order_id: 102, amount: 9.99, card: 'bad')
puts "  events: #{captured.map(&:name).inspect}"
puts "  payment.failed payload: #{captured.find { |e| e.name == 'payment.failed' }.payload}"

# ── Handling events — EventHandlers plugin ────────────────────────────────────

# Reset so only our handler sees the events below
Easyop::Events::Registry.reset!
Easyop::Events::Registry.bus = :memory

class AuditLog
  include Easyop::Operation
  plugin Easyop::Plugins::EventHandlers

  @entries = []
  class << self; attr_reader :entries; end

  on 'payment.**'   # glob: matches payment.charged, payment.failed, payment.attempted, etc.

  def call
    self.class.entries << "#{ctx.event.name} | #{ctx.event.payload.inspect}"
    puts "  [AuditLog] #{ctx.event.name}"
  end
end

class OrderSummaryUpdater
  include Easyop::Operation
  plugin Easyop::Plugins::EventHandlers

  on 'payment.charged'

  def call
    puts "  [OrderSummaryUpdater] updating summary for order #{ctx.event.payload[:order_id]}"
  end
end

puts "\nEvent handlers"
ProcessPayment.call(order_id: 201, amount: 20.0, card: '4111')
ProcessPayment.call(order_id: 202, amount: 5.0,  card: 'bad')

puts "\nAuditLog entries:"
AuditLog.entries.each { |e| puts "  #{e}" }

# ── Event object fields ────────────────────────────────────────────────────────

puts "\nEvent object"
Easyop::Events::Registry.reset!
Easyop::Events::Registry.bus = :memory

last_event = nil
Easyop::Events::Registry.bus.subscribe('payment.*') { |e| last_event = e }

ProcessPayment.call(order_id: 301, amount: 1.0, card: '4111')

puts "  name:      #{last_event.name}"
puts "  source:    #{last_event.source}"
puts "  payload:   #{last_event.payload.inspect}"
puts "  timestamp: #{last_event.timestamp.class}"
