# EasyOp — Usage Patterns

> Common patterns and recipes for LLMs helping users work with this gem.

## 1. Basic operation — single responsibility

```ruby
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
```

## 2. Chainable post-call callbacks

```ruby
AuthenticateUser.call(email: email, password: password)
  .on_success { |ctx| sign_in(ctx.user) }
  .on_failure { |ctx| flash[:alert] = ctx.error }
```

Both callbacks return `self` (the ctx), so they can be chained indefinitely.
They fire immediately after `.call` returns.

## 3. Bang variant — raise on failure

```ruby
# Use in service objects that expect a parent to rescue
begin
  ctx = AuthenticateUser.call!(email: email, password: password)
  # ctx.user is available here
rescue Easyop::Ctx::Failure => e
  e.ctx.error   # => "Invalid credentials"
  e.message     # => "Operation failed: Invalid credentials"
end
```

## 4. Before / after / around hooks

```ruby
class NormalizeEmail
  include Easyop::Operation

  before :strip_whitespace
  after  :log_result
  around :with_timing

  def call
    ctx.normalized = ctx.email.downcase
  end

  private

  def strip_whitespace
    ctx.email = ctx.email.to_s.strip
  end

  def log_result
    Rails.logger.info "Normalized: #{ctx.normalized}" if ctx.success?
  end

  def with_timing
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(2)
    Rails.logger.info "NormalizeEmail took #{elapsed}ms"
  end
end
```

Around hooks receive a callable (`inner`) as their argument — call `inner.call`
(or `yield` when using a method name). After hooks always run (in `ensure`).

## 5. rescue_from — centralized error handling

```ruby
class ParseJson
  include Easyop::Operation

  rescue_from JSON::ParserError do |e|
    ctx.fail!(error: "Invalid JSON: #{e.message}")
  end

  def call
    ctx.parsed = JSON.parse(ctx.raw)
  end
end
```

Multiple handlers, priority order, with: method reference:

```ruby
class ImportData
  include Easyop::Operation

  rescue_from CSV::MalformedCSVError, with: :handle_bad_csv
  rescue_from ActiveRecord::RecordInvalid do |e|
    ctx.fail!(error: e.message, errors: e.record.errors.to_h)
  end
  rescue_from StandardError, with: :handle_unexpected

  # ...
end
```

Child class handlers always take priority over parent class handlers for the same
exception class.

## 6. Typed input schema

```ruby
class RegisterUser
  include Easyop::Operation

  params do
    required :email,  String
    required :age,    Integer
    optional :plan,   String,   default: "free"
    optional :admin,  :boolean, default: false
  end

  def call
    ctx.user = User.create!(ctx.slice(:email, :age, :plan))
  end
end

result = RegisterUser.call(email: "alice@example.com", age: 30)
result.success?  # => true
result.plan      # => "free"  (default applied)

result = RegisterUser.call(email: "bob@example.com")
result.failure?  # => true
result.error     # => "Missing required params field: age"
```

## 7. ctx.slice — extract attributes as a plain Hash

```ruby
class CreateAccount
  include Easyop::Operation

  def call
    # Pass only the keys the AR model cares about
    ctx.account = Account.create!(ctx.slice(:name, :email, :plan))
  end
end
```

## 8. ctx.fail! with a structured errors hash

```ruby
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
result.errors   # => { quantity: "must be positive", item: "is required" }
result.error    # => "Validation failed"
```

## 9. Pattern matching (Ruby 3+)

```ruby
case RegisterUser.call(email: email, password: password)
in { success: true, user: User => user }
  sign_in(user)
  redirect_to dashboard_path
in { success: false, errors: Hash => errs }
  render :new, locals: { errors: errs }
in { success: false, error: String => msg }
  flash[:error] = msg
  render :new
end
```

## 10. Shared base class with rescue_from

```ruby
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
```

## 11. Flow — sequential composition

```ruby
class ProcessCheckout
  include Easyop::Flow

  flow ValidateCart,
       ApplyCoupon,     # optional — declares skip_if
       ChargePayment,
       CreateOrder,
       SendConfirmation
end

result = ProcessCheckout.call(user: current_user, cart: current_cart)
result.success?   # => true
result.order      # => #<Order ...>
```

Each step shares the same `ctx`. Failure in any step halts the chain.

## 12. skip_if — optional steps

```ruby
class ApplyCoupon
  include Easyop::Operation

  skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }

  def call
    ctx.discount = CouponService.apply(ctx.coupon_code)
  end
end
```

Skipped steps are never added to the rollback list.

Alternative: inline lambda guard in the flow list:

```ruby
flow ValidateCart,
     ->(ctx) { ctx.coupon_code? }, ApplyCoupon,
     ChargePayment
```

## 13. Rollback

```ruby
class ChargePayment
  include Easyop::Operation

  def call
    ctx.charge = Stripe::Charge.create(amount: ctx.total, source: ctx.token)
  end

  def rollback
    Stripe::Refund.create(charge: ctx.charge.id) if ctx.charge
  end
end
```

Rollback runs in reverse step order. Errors inside `rollback` are swallowed so
one broken rollback doesn't block the rest.

## 14. `prepare` — pre-registered callbacks (block style)

```ruby
ProcessCheckout.prepare
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| flash[:error] = ctx.error; redirect_back }
  .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])
```

Multiple callbacks are supported and run in registration order:

```ruby
ProcessCheckout.prepare
  .on_success { |ctx| Analytics.track("checkout", order: ctx.order) }
  .on_success { |ctx| redirect_to order_path(ctx.order) }
  .on_failure { |ctx| Rails.logger.error "Checkout failed: #{ctx.error}" }
  .on_failure { |ctx| render json: { error: ctx.error }, status: 422 }
  .call(attrs)
```

## 15. `prepare` with `bind_with` — Rails controller pattern

```ruby
# Controller action:
def create
  ProcessCheckout.prepare
    .bind_with(self)
    .on(success: :order_placed, fail: :checkout_failed)
    .call(user: current_user, cart: current_cart, coupon_code: params[:coupon])
end

private

def order_placed(ctx)
  redirect_to order_path(ctx.order), notice: "Order placed!"
end

def checkout_failed(ctx)
  flash[:error] = ctx.error
  render :new
end
```

Zero-arity methods are also supported (ctx is not passed):

```ruby
def order_placed
  redirect_to orders_path
end
```

## 16. Nested flows

A Flow can be a step inside another Flow:

```ruby
class AuthAndCharge
  include Easyop::Flow
  flow AuthenticateUser, ValidateCard
end

class FullCheckout
  include Easyop::Flow
  flow AuthAndCharge, CreateOrder, SendConfirmation
end
```

Ctx is shared across all nesting levels.

## 17. Testing operations with RSpec

```ruby
RSpec.describe CreateAccount do
  subject(:result) { described_class.call(name: "Alice", email: "alice@example.com") }

  it "succeeds" do
    expect(result).to be_success
    expect(result.account).to be_a(Account)
  end

  it "fails when email is blank" do
    result = described_class.call(name: "Alice", email: "")
    expect(result).to be_failure
    expect(result.error).to include("email")
  end
end
```

Anonymous inline classes for isolation:

```ruby
it "runs before hooks" do
  log = []
  op = Class.new do
    include Easyop::Operation
    before { log << :before }
    def call; log << :call; end
  end
  op.call
  expect(log).to eq([:before, :call])
end
```

## 19. Instrumentation plugin

```ruby
require "easyop/plugins/instrumentation"

class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Instrumentation
end

# config/initializers/easyop.rb
Easyop::Plugins::Instrumentation.attach_log_subscriber
# => logs: "[EasyOp] Users::Register ok (4.2ms)"

# Custom subscriber:
ActiveSupport::Notifications.subscribe("easyop.operation.call") do |event|
  p = event.payload
  MyAPM.record_span(p[:operation], duration: p[:duration], success: p[:success])
end
```

## 20. Recording plugin

```ruby
require "easyop/plugins/recording"

class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Recording, model: OperationLog
end

# Opt out for sensitive or high-frequency ops:
class Newsletter::SendBroadcast < ApplicationOperation
  recording false
end
```

Migration:
```ruby
create_table :operation_logs do |t|
  t.string   :operation_name, null: false
  t.boolean  :success,        null: false
  t.string   :error_message
  t.text     :params_data
  t.float    :duration_ms
  t.datetime :performed_at, null: false
end
```

## 21. Async plugin

```ruby
require "easyop/plugins/async"

class Reports::GenerateMonthlyPDF < ApplicationOperation
  plugin Easyop::Plugins::Async, queue: "reports"
end

# Enqueue:
Reports::GenerateMonthlyPDF.call_async(user_id: current_user.id, month: params[:month])

# With scheduling:
Reports::GenerateMonthlyPDF.call_async(user_id: 1, month: "2024-01", wait: 5.minutes)
Reports::GenerateMonthlyPDF.call_async(user_id: 1, month: "2024-01", wait_until: Date.tomorrow.noon)
```

## 22. Transactional plugin

```ruby
require "easyop/plugins/transactional"

# Per operation:
class TransferFunds < ApplicationOperation
  plugin Easyop::Plugins::Transactional

  def call
    ctx.from_account.debit!(ctx.amount)
    ctx.to_account.credit!(ctx.amount)
  end
end

# Globally (all ops get transactions):
class ApplicationOperation
  include Easyop::Operation
  plugin Easyop::Plugins::Transactional
end

# Opt out for read-only ops:
class ReportOp < ApplicationOperation
  transactional false
end

# Include style (also works):
class LegacyOp
  include Easyop::Operation
  include Easyop::Plugins::Transactional
end
```

## 23. Building a custom plugin

```ruby
require "easyop/plugins/base"

module AuditPlugin < Easyop::Plugins::Base
  def self.install(base, user_context:, **_opts)
    base.prepend(RunWrapper)
    base.extend(ClassMethods)
    base.instance_variable_set(:@_audit_user_context, user_context)
  end

  module ClassMethods
    def audit(enabled); @_audit_enabled = enabled; end

    def _audit_enabled?
      return @_audit_enabled if instance_variable_defined?(:@_audit_enabled)
      superclass.respond_to?(:_audit_enabled?) ? superclass._audit_enabled? : true
    end

    def _audit_user_context
      @_audit_user_context || (superclass.respond_to?(:_audit_user_context) ? superclass._audit_user_context : nil)
    end
  end

  module RunWrapper
    def _easyop_run(ctx, raise_on_failure:)
      return super unless self.class._audit_enabled?
      super.tap do
        AuditLog.create!(
          actor:     self.class._audit_user_context&.call,
          operation: self.class.name,
          success:   ctx.success?,
          at:        Time.current
        )
      end
    end
  end
end

# Use it:
class ApplicationOperation
  include Easyop::Operation
  plugin AuditPlugin, user_context: -> { Current.user }
end
```

## 18. Common mistakes

```ruby
# ❌ Using bare yield in prepare (ancient bug — already fixed)
def prepare
  inner = proc { yield }   # doesn't work when called via chain.call
  call_through_around(around_hooks, inner)
end

# ✅ Capture &block explicitly
def prepare(&block)
  inner = proc { block.call }
  call_through_around(around_hooks, inner)
end

# ❌ Calling .flow with no args expecting a builder
ProcessCheckout.flow.on_success { ... }  # flow() with no args raises or returns nil

# ✅ Use prepare
ProcessCheckout.prepare.on_success { ... }

# ❌ Forgetting that skip_if only applies when running inside a Flow
ApplyCoupon.call(coupon_code: "")  # skip_if is NOT checked — step runs directly

# ✅ skip_if is a Flow concern — direct .call always runs the step
```
