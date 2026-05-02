#!/usr/bin/env ruby
# frozen_string_literal: true

# 04 — Params Schema
#
# Covers:
#   params do ... end block
#   required / optional fields
#   Type coercion: Integer, Float, String, :boolean, :symbol, custom classes
#   Default values for optional fields
#   result do ... end block
#   ctx.fail! on missing / wrong type
#
# Run: ruby examples/code/04_params_schema.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'

# Enable strict type checking so mismatches fail the ctx instead of just warning.
Easyop.configure { |c| c.strict_types = true }

puts '─' * 50
puts '04 — Params Schema'
puts '─' * 50

# ── required vs optional, defaults ───────────────────────────────────────────

class CreateOrder
  include Easyop::Operation

  params do
    required :item,        String
    required :quantity,    Integer
    required :unit_price,  Float
    optional :coupon,      String,   default: nil
    optional :priority,    :boolean, default: false
    optional :currency,    String,   default: 'USD'
  end

  def call
    subtotal    = ctx.quantity * ctx.unit_price
    ctx.total   = ctx.coupon == 'SAVE10' ? subtotal * 0.90 : subtotal
    ctx.summary = "#{ctx.quantity}× #{ctx.item} @ #{ctx.unit_price} #{ctx.currency}"
  end
end

puts "\nAll required + some optional"
r = CreateOrder.call(item: 'Widget', quantity: 3, unit_price: 9.99, coupon: 'SAVE10')
puts "  total:    #{r.total.round(2)}"      # 26.97
puts "  summary:  #{r.summary}"
puts "  priority: #{r.priority}"            # default false
puts "  currency: #{r.currency}"            # default 'USD'

puts "\nMissing required field"
r = CreateOrder.call(item: 'Gadget')
puts "  failure? #{r.failure?}"
puts "  error:   #{r.error}"

puts "\nWrong type for Integer field"
r = CreateOrder.call(item: 'Thing', quantity: 'three', unit_price: 5.0)
puts "  failure? #{r.failure?}"
puts "  error:   #{r.error}"

# ── :symbol and :boolean type shorthands ─────────────────────────────────────

class UpdateSettings
  include Easyop::Operation

  params do
    required :user_id,          Integer
    optional :theme,            :symbol,  default: :light
    optional :notifications,    :boolean, default: true
    optional :items_per_page,   Integer,  default: 20
  end

  def call
    ctx.applied = "user=#{ctx.user_id} theme=#{ctx.theme} " \
                  "notif=#{ctx.notifications} per_page=#{ctx.items_per_page}"
  end
end

puts "\n:symbol and :boolean shorthands"
r = UpdateSettings.call(user_id: 7, theme: :dark, notifications: false)
puts "  #{r.applied}"

r = UpdateSettings.call(user_id: 8)   # all defaults
puts "  defaults → #{r.applied}"

# ── Custom class type checking ────────────────────────────────────────────────

User = Struct.new(:id, :email)

class SendWelcome
  include Easyop::Operation

  params do
    required :user, User       # accepts User instances only
    optional :message, String, default: 'Welcome aboard!'
  end

  def call
    ctx.sent_to = ctx.user.email
  end
end

puts "\nCustom class type checking"
r = SendWelcome.call(user: User.new(1, 'alice@example.com'))
puts "  sent_to: #{r.sent_to}"

r = SendWelcome.call(user: 'not a User')
puts "  wrong type → failure? #{r.failure?}  error: #{r.error}"

# ── result schema ─────────────────────────────────────────────────────────────

class RegisterUser
  include Easyop::Operation

  params do
    required :email, String
    required :name,  String
  end

  result do
    required :user_id, String
    required :welcome, String
  end

  def call
    ctx.user_id = "usr_#{ctx.email.hash.abs % 100_000}"
    ctx.welcome = "Hello, #{ctx.name}!"
  end
end

puts "\nresult schema"
r = RegisterUser.call(email: 'bob@example.com', name: 'Bob')
puts "  user_id: #{r.user_id}"
puts "  welcome: #{r.welcome}"
