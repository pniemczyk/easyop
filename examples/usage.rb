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

puts "\n" + "=" * 60
puts "All examples complete."
