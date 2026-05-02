#!/usr/bin/env ruby
# frozen_string_literal: true

# 07 — Recording Plugin
#
# Covers:
#   plugin Easyop::Plugins::Recording, model: ...
#   Automatic params_data + result_data persistence
#   filter_params — replaces value with "[FILTERED]"
#   encrypt_params — stores encrypted marker { "$easyop_encrypted" => "..." }
#   record_result — captures ctx keys in result_data
#   recording false — opt out per operation
#   Flow tree tracing: root_reference_id shared across all steps
#
# Note: uses an in-memory OperationLog (no database needed).
#
# Run: ruby examples/code/07_recording.rb

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'easyop'
require 'easyop/simple_crypt'
require 'easyop/plugins/recording'
require 'json'

# Rails compatibility shims for standalone execution.
# activesupport may be in the load path (dev env). Pre-require all Time-related
# extensions first, then override Time.current with a plain Time.now so we don't
# depend on Rails timezone infrastructure (IsolatedExecutionState etc).
begin
  require 'active_support/core_ext/time/calculations'
  require 'active_support/message_encryptor'
rescue LoadError
  nil
end
class Time
  def self.current; now; end
end
unless defined?(ActiveRecord::Base)
  module ActiveRecord; class Base; end; end
end

puts '─' * 50
puts '07 — Recording Plugin'
puts '─' * 50

# ── Minimal in-memory OperationLog ─────────────────────────────────────────────

RECORDED_COLUMNS = %w[
  operation_name success error_message params_data duration_ms performed_at
  root_reference_id reference_id parent_operation_name parent_reference_id
  result_data execution_index
].freeze

OperationLog = Struct.new(*RECORDED_COLUMNS.map(&:to_sym), keyword_init: true)

class OperationLog
  @store = []
  def self.store;        @store;           end
  def self.column_names; RECORDED_COLUMNS; end
  def self.create!(attrs)
    @store << new(**attrs.slice(*RECORDED_COLUMNS.map(&:to_sym)))
  end
end

# ── Configure recording secret for encrypt_params ─────────────────────────────

Easyop.configure do |c|
  c.recording_secret = 'a-secret-key-that-is-at-least-32-bytes-long!!'
end

# ── Base operation with Recording installed ────────────────────────────────────

class AppOp
  include Easyop::Operation
  plugin Easyop::Plugins::Recording, model: OperationLog
end

# ── Basic recording: params_data captured automatically ───────────────────────

class RegisterUser < AppOp
  params do
    required :email, String
    required :name,  String
  end

  def call
    ctx.user_id = "usr_#{ctx.email.hash.abs % 100_000}"
  end
end

puts "\nBasic recording"
RegisterUser.call(email: 'alice@example.com', name: 'Alice')
log = OperationLog.store.last
puts "  operation_name: #{log.operation_name}"
puts "  success:        #{log.success}"
puts "  params_data:    #{log.params_data}"

# ── filter_params — sensitive data replaced with [FILTERED] ───────────────────

class AuthenticateUser < AppOp
  params do
    required :email,    String
    required :password, String   # password is auto-filtered (FILTERED_KEYS)
  end

  filter_params :session_token   # explicit filter

  def call
    ctx.authenticated = true
    ctx.session_token = "tok_#{SecureRandom.hex(8)}"
  end
end

puts "\nfilter_params"
OperationLog.store.clear
AuthenticateUser.call(email: 'bob@example.com', password: 'hunter2', session_token: 'raw-token')
log    = OperationLog.store.last
params = JSON.parse(log.params_data)
puts "  password:      #{params['password']}"       # [FILTERED]
puts "  session_token: #{params['session_token']}"  # [FILTERED] (explicit)
puts "  email:         #{params['email']}"          # stored normally

# ── encrypt_params — sensitive data encrypted at rest ─────────────────────────

class ChargeCard < AppOp
  params do
    required :amount_cents,       Integer
    required :credit_card_number, String
    required :cvv,                String
  end

  encrypt_params :credit_card_number, :cvv

  record_result attrs: %i[charge_id]

  def call
    ctx.charge_id = "ch_#{SecureRandom.hex(8)}"
  end
end

puts "\nencrypt_params"
OperationLog.store.clear
ChargeCard.call(amount_cents: 4999, credit_card_number: '4111111111111111', cvv: '123')
log    = OperationLog.store.last
params = JSON.parse(log.params_data)
result = JSON.parse(log.result_data)
puts "  amount_cents:       #{params['amount_cents']}"
puts "  credit_card_number: #{params['credit_card_number'].keys.inspect}"  # ["$easyop_encrypted"]
puts "  cvv:                #{params['cvv'].keys.inspect}"                  # ["$easyop_encrypted"]
puts "  result charge_id:   #{result['charge_id']}"

# Decrypt to verify the value is recoverable
encrypted = params['credit_card_number']
decrypted = Easyop::SimpleCrypt.decrypt_marker(encrypted)
puts "  decrypted CC:       #{decrypted}"             # 4111111111111111

# ── recording false — opt out per class ───────────────────────────────────────

class InternalHealthCheck < AppOp
  recording false

  def call
    ctx.status = :ok
  end
end

puts "\nrecording false (opt out)"
OperationLog.store.clear
InternalHealthCheck.call
puts "  logs created: #{OperationLog.store.size}"   # 0

# ── Flow tree tracing — shared root_reference_id ──────────────────────────────

class DebitAccount < AppOp
  def call
    ctx.debited = true
  end
end

class CreditAccount < AppOp
  def call
    ctx.credited = true
  end
end

class TransferFlow
  include Easyop::Flow
  flow DebitAccount, CreditAccount
end

puts "\nFlow tree tracing"
OperationLog.store.clear
TransferFlow.call(from: 'alice', to: 'bob', amount: 50)

root_ids = OperationLog.store.map(&:root_reference_id).compact.uniq
puts "  logs recorded: #{OperationLog.store.size}"
puts "  unique root_reference_ids: #{root_ids.size}"    # 1 — all share the same root
OperationLog.store.each do |log|
  puts "  #{log.operation_name.ljust(35)} parent=#{log.parent_operation_name.inspect}"
end
