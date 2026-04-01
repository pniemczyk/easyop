# frozen_string_literal: true

# EasyOp — RSpec Testing Examples

# ── 1. Testing a basic operation ──────────────────────────────────────────────

RSpec.describe DoubleNumber do
  describe ".call" do
    context "with a valid number" do
      subject(:ctx) { described_class.call(number: 7) }

      it { is_expected.to be_success }
      it { expect(ctx.result).to eq(14) }
    end

    context "with invalid input" do
      subject(:ctx) { described_class.call(number: "oops") }

      it { is_expected.to be_failure }
      it { expect(ctx.error).to eq("input must be a number") }
    end
  end

  describe ".call!" do
    it "raises Easyop::Ctx::Failure on failure" do
      expect { described_class.call!(number: "bad") }
        .to raise_error(Easyop::Ctx::Failure, /input must be a number/)
    end

    it "returns ctx on success" do
      ctx = described_class.call!(number: 5)
      expect(ctx.result).to eq(10)
    end
  end
end

# ── 2. Testing with structured errors ────────────────────────────────────────

RSpec.describe ValidateOrder do
  subject(:ctx) { described_class.call(quantity: -1, item: "", unit_price: 10) }

  it { is_expected.to be_failure }
  it { expect(ctx.errors[:quantity]).to eq("must be positive") }
  it { expect(ctx.errors[:item]).to eq("is required") }
end

# ── 3. Testing hooks ──────────────────────────────────────────────────────────

RSpec.describe NormalizeEmail do
  subject(:ctx) { described_class.call(email: "  Alice@Example.COM  ") }

  it "strips and downcases email via before hook" do
    expect(ctx.normalized).to eq("alice@example.com")
  end

  it "logs after success" do
    expect { described_class.call(email: "Bob@Test.com") }
      .to output(/normalized to: bob@test.com/).to_stdout
  end
end

# ── 4. Testing rescue_from ────────────────────────────────────────────────────

RSpec.describe ParseJson do
  context "with valid JSON" do
    subject(:ctx) { described_class.call(raw: '{"name":"Alice"}') }

    it { is_expected.to be_success }
    it { expect(ctx.parsed).to eq("name" => "Alice") }
  end

  context "with invalid JSON" do
    subject(:ctx) { described_class.call(raw: "not json") }

    it { is_expected.to be_failure }
    it { expect(ctx.error).to match(/Invalid JSON/) }
  end
end

# ── 5. Testing typed params schema ────────────────────────────────────────────

RSpec.describe RegisterUser do
  context "with all required params" do
    subject(:ctx) { described_class.call(email: "alice@example.com", age: 30) }

    it { is_expected.to be_success }
    it { expect(ctx.plan).to eq("free") }   # default applied
    it { expect(ctx.admin).to eq(false) }    # default applied
  end

  context "missing required param" do
    subject(:ctx) { described_class.call(email: "bob@example.com") }

    it { is_expected.to be_failure }
    it { expect(ctx.error).to match(/age/) }
  end
end

# ── 6. Testing ctx.slice ──────────────────────────────────────────────────────

RSpec.describe CreateAccount do
  it "passes only relevant keys to Account.create!" do
    expect(Account).to receive(:create!).with(
      name: "Alice", email: "alice@example.com", plan: "free"
    ).and_return(double(Account))

    described_class.call(name: "Alice", email: "alice@example.com", plan: "free", extra: "ignored")
  end
end

# ── 7. Testing inline anonymous operations ────────────────────────────────────
# Useful for unit-testing operation behavior in isolation without defining a
# named class globally.

RSpec.describe "an inline operation" do
  let(:op_class) do
    Class.new do
      include Easyop::Operation

      def call
        ctx.result = ctx.x + ctx.y
      end
    end
  end

  it "sums two numbers" do
    ctx = op_class.call(x: 3, y: 4)
    expect(ctx.result).to eq(7)
  end
end

# ── 8. Testing a flow ─────────────────────────────────────────────────────────

RSpec.describe ProcessCheckout do
  let(:user) { double("User") }
  let(:cart) { double("Cart", items: [double(price: 100)]) }

  context "when checkout succeeds" do
    before do
      allow(Stripe::Charge).to receive(:create).and_return(double(id: "ch_123"))
      allow(Order).to receive(:create!).and_return(double(id: 42, persisted?: true))
      allow(OrderMailer).to receive_message_chain(:confirmation, :deliver_later)
    end

    subject(:ctx) { described_class.call(user: user, cart: cart, payment_token: "tok_test") }

    it { is_expected.to be_success }
    it { expect(ctx.total).to eq(100) }
  end

  context "when the cart is empty" do
    let(:cart) { double("Cart", items: []) }

    subject(:ctx) { described_class.call(user: user, cart: cart, payment_token: "tok") }

    it { is_expected.to be_failure }
    it { expect(ctx.error).to eq("Cart is empty") }
  end

  context "when an optional coupon is absent" do
    before do
      allow(Stripe::Charge).to receive(:create).and_return(double(id: "ch_456"))
      allow(Order).to receive(:create!).and_return(double(id: 99, persisted?: true))
      allow(OrderMailer).to receive_message_chain(:confirmation, :deliver_later)
    end

    subject(:ctx) do
      described_class.call(user: user, cart: cart, payment_token: "tok", coupon_code: "")
    end

    it "skips ApplyCoupon" do
      expect(Coupon).not_to receive(:find_by)
      expect(ctx).to be_success
    end

    it { expect(ctx.discount).to be_nil }
  end
end

# ── 9. Testing rollback ───────────────────────────────────────────────────────

RSpec.describe ProcessCheckout do
  let(:user)   { double("User") }
  let(:cart)   { double("Cart", items: [double(price: 50)]) }
  let(:charge) { double("Charge", id: "ch_rollback") }

  context "when CreateOrder fails after ChargePayment succeeded" do
    before do
      allow(Stripe::Charge).to receive(:create).and_return(charge)
      allow(Order).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(double(errors: double(full_messages: ["invalid"]))))
      allow(Stripe::Refund).to receive(:create)
    end

    subject(:ctx) { described_class.call(user: user, cart: cart, payment_token: "tok") }

    it { is_expected.to be_failure }

    it "rolls back the charge" do
      ctx
      expect(Stripe::Refund).to have_received(:create).with(charge: "ch_rollback")
    end
  end
end

# ── 10. Testing prepare (FlowBuilder) ──────────────────────────────────────

RSpec.describe ProcessCheckout do
  let(:user) { double("User") }
  let(:cart) { double("Cart", items: [double(price: 20)]) }

  describe ".prepare" do
    context "on success" do
      before do
        allow(Stripe::Charge).to receive(:create).and_return(double(id: "ch_ok"))
        allow(Order).to receive(:create!).and_return(double(id: 1, persisted?: true))
        allow(OrderMailer).to receive_message_chain(:confirmation, :deliver_later)
      end

      it "fires on_success callbacks" do
        fired = false
        described_class.prepare
          .on_success { fired = true }
          .call(user: user, cart: cart, payment_token: "tok")

        expect(fired).to be true
      end
    end

    context "on failure" do
      let(:cart) { double("Cart", items: []) }

      it "fires on_failure callbacks" do
        error_received = nil
        described_class.prepare
          .on_failure { |ctx| error_received = ctx.error }
          .call(user: user, cart: cart, payment_token: "tok")

        expect(error_received).to eq("Cart is empty")
      end
    end

    context "with bind_with and symbol callbacks" do
      let(:host) do
        Class.new do
          attr_reader :last_ctx
          def order_placed(ctx) = (@last_ctx = ctx)
          def checkout_failed(ctx) = (@last_ctx = ctx)
        end.new
      end

      let(:cart) { double("Cart", items: []) }

      it "calls the named method on the bound object" do
        described_class.prepare
          .bind_with(host)
          .on(success: :order_placed, fail: :checkout_failed)
          .call(user: user, cart: cart, payment_token: "tok")

        expect(host.last_ctx).to be_failure
      end
    end
  end
end

# ── 11. Testing skip_if (unit-level) ─────────────────────────────────────────

RSpec.describe ApplyCoupon do
  describe ".skip?" do
    it "skips when coupon_code is absent" do
      ctx = Easyop::Ctx.new({})
      expect(described_class.skip?(ctx)).to be true
    end

    it "skips when coupon_code is empty string" do
      ctx = Easyop::Ctx.new(coupon_code: "")
      expect(described_class.skip?(ctx)).to be true
    end

    it "does not skip when coupon_code is present" do
      ctx = Easyop::Ctx.new(coupon_code: "SAVE10")
      expect(described_class.skip?(ctx)).to be false
    end
  end
end

# ── 12. Resetting configuration between tests ────────────────────────────────

# Add to spec/spec_helper.rb to ensure each test starts with a clean config:
RSpec.configure do |config|
  config.before(:each) do
    Easyop.reset_config!
  end
end

# Or reset in a specific test:
RSpec.describe "strict_types behavior" do
  after { Easyop.reset_config! }

  it "fails on type mismatch when strict_types is enabled" do
    Easyop.configure { |c| c.strict_types = true }

    op = Class.new do
      include Easyop::Operation
      params { required :age, Integer }
      def call; end
    end

    result = op.call(age: "not a number")
    expect(result).to be_failure
    expect(result.error).to match(/Type mismatch/)
  end
end

# ── 13. Testing shared ApplicationOperation base ──────────────────────────────

RSpec.describe ApplicationOperation do
  describe "rescue_from ActiveRecord::RecordInvalid" do
    let(:op_class) do
      Class.new(ApplicationOperation) do
        def call
          raise ActiveRecord::RecordInvalid.new(double(errors: double(
            full_messages: ["Email is invalid"],
            group_by_attribute: { "email" => [double(message: "is invalid")] }
          )))
        end
      end
    end

    subject(:ctx) { op_class.call }

    it { is_expected.to be_failure }
    it { expect(ctx.error).to eq("Email is invalid") }
    it { expect(ctx.errors).to eq("email" => ["is invalid"]) }
  end

  describe "rescue_from ActiveRecord::RecordNotFound" do
    let(:op_class) do
      Class.new(ApplicationOperation) do
        def call
          raise ActiveRecord::RecordNotFound.new(nil, User)
        end
      end
    end

    subject(:ctx) { op_class.call }

    it { is_expected.to be_failure }
    it { expect(ctx.error).to eq("User not found") }
  end
end
