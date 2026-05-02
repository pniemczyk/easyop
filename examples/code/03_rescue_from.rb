#!/usr/bin/env ruby
# frozen_string_literal: true

# 03 — rescue_from
#
# Covers:
#   rescue_from ExceptionClass do |e| ... end
#   Handler can call ctx.fail! or let it re-raise
#   Inheritance: child class inherits parent's rescue_from handlers
#   Multiple rescue_from declarations (most-derived wins)
#
# Run: ruby examples/code/03_rescue_from.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'
require 'json'

puts '─' * 50
puts '03 — rescue_from'
puts '─' * 50

# ── Basic rescue_from ─────────────────────────────────────────────────────────

class ParseJson
  include Easyop::Operation

  rescue_from JSON::ParserError do |e|
    ctx.fail!(error: "Invalid JSON: #{e.message.lines.first.strip}")
  end

  def call
    ctx.parsed = JSON.parse(ctx.raw)
  end
end

puts "\nParse valid JSON"
r = ParseJson.call(raw: '{"name":"Alice","age":30}')
puts "  parsed: #{r.parsed}"

puts "\nParse invalid JSON"
r = ParseJson.call(raw: 'not json at all')
puts "  failure? #{r.failure?}"
puts "  error:   #{r.error[0, 60]}"

# ── Shared base class with rescue_from ───────────────────────────────────────

class ApplicationOp
  include Easyop::Operation

  # Catch-all: any StandardError not handled by a subclass
  rescue_from StandardError do |e|
    puts "  [ApplicationOp] caught #{e.class}: #{e.message}"
    ctx.fail!(error: 'An unexpected error occurred')
  end
end

class FetchUser < ApplicationOp
  # More specific handler for RuntimeError overrides the base class one
  rescue_from RuntimeError do |e|
    ctx.fail!(error: "User fetch failed: #{e.message}")
  end

  def call
    raise RuntimeError, "user 99 not found" if ctx.user_id == 99
    raise ArgumentError, "id must be positive" if ctx.user_id.to_i <= 0
    ctx.user = { id: ctx.user_id, name: "Alice" }
  end
end

puts "\nFetchUser — RuntimeError (specific handler)"
r = FetchUser.call(user_id: 99)
puts "  error: #{r.error}"                  # handled by FetchUser's handler

puts "\nFetchUser — ArgumentError (base class handler)"
r = FetchUser.call(user_id: -1)
puts "  error: #{r.error}"                  # handled by ApplicationOp's handler

puts "\nFetchUser — success"
r = FetchUser.call(user_id: 1)
puts "  user: #{r.user}"

# ── rescue_from without ctx.fail! re-raises ────────────────────────────────────

class DangerousOp
  include Easyop::Operation

  rescue_from ZeroDivisionError do |e|
    puts "  [rescue_from] caught ZeroDivisionError — re-raising"
    raise  # re-raise the original exception
  end

  def call
    ctx.result = 10 / ctx.divisor
  end
end

puts "\nrescue_from that re-raises"
begin
  DangerousOp.call!(divisor: 0)
rescue ZeroDivisionError => e
  puts "  ZeroDivisionError propagated: #{e.message}"
end
