# frozen_string_literal: true

# EasyOp — Basic Operation Examples
# These are illustrative patterns, not runnable standalone scripts.
# See examples/usage.rb for a full runnable demo.

# ── 1. Minimal operation ─────────────────────────────────────────────────────

class DoubleNumber
  include Easyop::Operation

  def call
    ctx.fail!(error: "input must be a number") unless ctx.number.is_a?(Numeric)
    ctx.result = ctx.number * 2
  end
end

result = DoubleNumber.call(number: 21)
result.success?  # => true
result.result    # => 42

result = DoubleNumber.call(number: "oops")
result.failure?  # => true
result.error     # => "input must be a number"

# ── 2. Before / after hooks ──────────────────────────────────────────────────

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
    puts "[log] normalized to: #{ctx.normalized}" if ctx.success?
  end
end

result = NormalizeEmail.call(email: "  Alice@Example.COM  ")
result.normalized  # => "alice@example.com"

# ── 3. rescue_from ───────────────────────────────────────────────────────────

require "json"

class ParseJson
  include Easyop::Operation

  rescue_from JSON::ParserError do |e|
    ctx.fail!(error: "Invalid JSON: #{e.message.lines.first.strip}")
  end

  def call
    ctx.parsed = JSON.parse(ctx.raw)
  end
end

ParseJson.call(raw: '{"name":"Alice"}').parsed  # => {"name" => "Alice"}
ParseJson.call(raw: "not json").failure?         # => true

# ── 4. Typed params schema ───────────────────────────────────────────────────

class RegisterUser
  include Easyop::Operation

  params do
    required :email, String
    required :age,   Integer
    optional :plan,  String,   default: "free"
    optional :admin, :boolean, default: false
  end

  def call
    ctx.user_id = "usr_#{ctx.email.hash.abs}"
  end
end

result = RegisterUser.call(email: "alice@example.com", age: 30)
result.plan   # => "free"  (default applied)
result.admin  # => false   (default applied)

result = RegisterUser.call(email: "bob@example.com")
result.failure?  # => true
result.error     # => "Missing required params field: age"

# ── 5. ctx.fail! with structured errors ─────────────────────────────────────

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

result = ValidateOrder.call(quantity: -1, item: "", unit_price: 10)
result.errors  # => { quantity: "must be positive", item: "is required" }

result = ValidateOrder.call(quantity: 3, item: "Widget", unit_price: 5)
result.total   # => 15

# ── 6. ctx.slice — extract a subset ─────────────────────────────────────────

class CreateAccount
  include Easyop::Operation

  def call
    # Pass only the keys Account cares about
    ctx.account = Account.create!(ctx.slice(:name, :email, :plan))
  end
end

# ── 7. Chainable callbacks ───────────────────────────────────────────────────

DoubleNumber.call(number: 7)
  .on_success { |ctx| puts "Result: #{ctx.result}" }
  .on_failure { |ctx| puts "Error: #{ctx.error}" }

# ── 8. Pattern matching (Ruby 3+) ────────────────────────────────────────────

result = DoubleNumber.call(number: 5)
case result
in { success: true, result: Integer => n } then puts "Doubled: #{n}"
in { success: false, error: String => e }  then puts "Error: #{e}"
end

# ── 9. Bang variant (.call!) ─────────────────────────────────────────────────

begin
  ctx = DoubleNumber.call!(number: "bad")
rescue Easyop::Ctx::Failure => e
  e.ctx.error   # => "input must be a number"
  e.message     # => "Operation failed: input must be a number"
end

# ── 10. Shared base class ─────────────────────────────────────────────────────

class ApplicationOperation
  include Easyop::Operation

  rescue_from StandardError do |e|
    Sentry.capture_exception(e)
    ctx.fail!(error: "An unexpected error occurred")
  end
end

class RiskyOp < ApplicationOperation
  def call
    raise "Something exploded"
  end
end

RiskyOp.call.error  # => "An unexpected error occurred"

# ── 11. ctx.key? — explicit existence check ──────────────────────────────────

result = DoubleNumber.call(number: 21)
result.key?(:result)   # => true  (key was set)
result.key?(:missing)  # => false (never set)

# Contrast with the predicate syntax:
result.result?         # => !!result[:result] — tests truthiness, not existence
result.key?(:result)   # => true — tests existence (even for nil/false values)

# ── 12. ctx.ok? and ctx.failed? (status aliases) ─────────────────────────────

result = DoubleNumber.call(number: 5)
result.success?   # => true
result.ok?        # => true  (alias for success?)

result = DoubleNumber.call(number: "bad")
result.failure?   # => true
result.failed?    # => true  (alias for failure?)

# ── 13. inputs / outputs aliases ─────────────────────────────────────────────

class NormalizeAddress
  include Easyop::Operation

  inputs do          # alias for params
    required :street, String
    required :city,   String
  end

  outputs do         # alias for result
    required :formatted, String
  end

  def call
    ctx.formatted = "#{ctx.street}, #{ctx.city}"
  end
end

result = NormalizeAddress.call(street: "123 Main St", city: "Springfield")
result.formatted  # => "123 Main St, Springfield"

# ── 14. Easyop.configure ─────────────────────────────────────────────────────

Easyop.configure do |c|
  c.strict_types  = true     # ctx.fail! on type mismatch (default: false — warns)
  c.type_adapter  = :native  # :none, :native (default), :literal, :dry, :active_model
end

# Reset to defaults (always call in spec before_each or after_each):
Easyop.reset_config!
