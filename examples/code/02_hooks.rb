#!/usr/bin/env ruby
# frozen_string_literal: true

# 02 — Hooks
#
# Covers:
#   before / after hooks — symbol (method name) and block forms
#   around hooks — wraps the call body
#   Hook execution order: before → call → after → around outer
#   Hooks inherited by subclasses
#
# Run: ruby examples/code/02_hooks.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'

puts '─' * 50
puts '02 — Hooks'
puts '─' * 50

# ── before / after with symbol (method reference) ────────────────────────────

class NormalizeAndLog
  include Easyop::Operation

  before :strip_and_downcase    # calls the private method before #call
  after  :log_result            # calls the private method after #call

  def call
    ctx.normalized = ctx.email
  end

  private

  def strip_and_downcase
    ctx.email = ctx.email.to_s.strip.downcase
  end

  def log_result
    puts "  [after]  normalized → #{ctx.normalized}" if ctx.success?
  end
end

puts "\nbefore/after (symbol form)"
result = NormalizeAndLog.call(email: '  ALICE@EXAMPLE.COM  ')
puts "  result: #{result.normalized}"

# ── before / after with block ─────────────────────────────────────────────────

class AuditOp
  include Easyop::Operation

  before { puts "  [before] starting with ctx keys: #{ctx.to_h.keys.inspect}" }
  after  { puts "  [after]  success=#{ctx.success?}" }

  def call
    ctx.answer = 42
  end
end

puts "\nbefore/after (block form)"
AuditOp.call

# ── around hook — measures elapsed time ──────────────────────────────────────

class TimedOp
  include Easyop::Operation

  around do |inner|
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    inner.call
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000).round(3)
    puts "  [around] elapsed #{elapsed_ms} ms"
  end

  def call
    ctx.sum = (1..10_000).sum
  end
end

puts "\naround hook (timing)"
result = TimedOp.call
puts "  sum = #{result.sum}"

# ── Hook execution order ──────────────────────────────────────────────────────

class OrderDemo
  include Easyop::Operation

  around do |inner|
    puts "  around — outer before"
    inner.call
    puts "  around — outer after"
  end

  before { puts "  before" }
  after  { puts "  after"  }

  def call
    puts "  call"
  end
end

puts "\nhook execution order"
OrderDemo.call
# Prints: around outer before → before → call → after → around outer after

# ── Hooks inherited by subclasses ────────────────────────────────────────────

class BaseOp
  include Easyop::Operation
  before { puts "  [base before]" }
end

class ChildOp < BaseOp
  before { puts "  [child before]" }

  def call
    puts "  [child call]"
  end
end

puts "\nhook inheritance (base before runs first)"
ChildOp.call
