#!/usr/bin/env ruby
# frozen_string_literal: true

# 01 — Basic Operation
#
# Covers:
#   include Easyop::Operation
#   .call / .call!
#   ctx.fail! / ctx.success? / ctx.failure?
#   .on_success / .on_failure callbacks
#   Pattern matching on the result
#
# Run: ruby examples/code/01_basic_operation.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'

puts '─' * 50
puts '01 — Basic Operation'
puts '─' * 50

# ── Define ────────────────────────────────────────────────────────────────────

class DoubleNumber
  include Easyop::Operation

  def call
    ctx.fail!(error: 'input must be a number') unless ctx.number.is_a?(Numeric)
    ctx.result = ctx.number * 2
  end
end

# ── .call returns a ctx you can interrogate ───────────────────────────────────

result = DoubleNumber.call(number: 21)
puts "\n.call(number: 21)"
puts "  success? #{result.success?}"
puts "  result:  #{result.result}"          # => 42

result = DoubleNumber.call(number: 'oops')
puts "\n.call(number: 'oops')"
puts "  failure? #{result.failure?}"
puts "  error:   #{result.error}"

# ── .call! raises Easyop::Ctx::Failure on failure ────────────────────────────

puts "\n.call!(number: 7)"
result = DoubleNumber.call!(number: 7)
puts "  result: #{result.result}"           # => 14

begin
  DoubleNumber.call!(number: 'bang')
rescue Easyop::Ctx::Failure => e
  puts "\n.call!(number: 'bang') raised Easyop::Ctx::Failure"
  puts "  message: #{e.message}"
end

# ── on_success / on_failure callbacks ────────────────────────────────────────

puts "\nChained callbacks"

DoubleNumber.call(number: 5)
  .on_success { |ctx| puts "  on_success: #{ctx.result}" }     # => 10
  .on_failure { |ctx| puts "  on_failure: #{ctx.error}" }

DoubleNumber.call(number: 'nope')
  .on_success { |ctx| puts "  on_success: #{ctx.result}" }
  .on_failure { |ctx| puts "  on_failure: #{ctx.error}" }      # => ...

# ── Pattern matching (Ruby 3+) ────────────────────────────────────────────────

puts "\nPattern matching"

result = DoubleNumber.call(number: 9)
verdict = case result
          in { success: true,  result: Integer => n } then "doubled to #{n}"
          in { success: false, error:  String  => e } then "error: #{e}"
          end
puts "  #{verdict}"                                            # => doubled to 18

# ── ctx[] hash access ─────────────────────────────────────────────────────────

puts "\nctx[] hash-style access"
result = DoubleNumber.call(number: 3)
puts "  result[:result] = #{result[:result]}"
puts "  result[:missing] = #{result[:missing].inspect}"       # nil — safe, no KeyError

# ── ctx.slice ─────────────────────────────────────────────────────────────────

puts "\nctx.slice"
result = DoubleNumber.call(number: 4)
puts "  slice(:result, :success) = #{result.slice(:result, :success)}"
