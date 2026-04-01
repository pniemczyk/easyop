require "spec_helper"

RSpec.describe Easyop::Ctx do
  subject(:ctx) { described_class.new(name: "Alice", age: 30) }

  # ── Construction ────────────────────────────────────────────────────────────

  describe ".build" do
    it "wraps a plain hash in a Ctx" do
      result = described_class.build(x: 1)
      expect(result).to be_a(described_class)
      expect(result[:x]).to eq(1)
    end

    it "returns an existing Ctx unchanged" do
      result = described_class.build(ctx)
      expect(result).to be(ctx)
    end
  end

  # ── Attribute access ─────────────────────────────────────────────────────────

  describe "attribute access" do
    it "supports [] and []=" do
      ctx[:score] = 99
      expect(ctx[:score]).to eq(99)
    end

    it "supports method-style readers for existing keys" do
      expect(ctx.name).to eq("Alice")
      expect(ctx.age).to  eq(30)
    end

    it "supports method-style writers" do
      ctx.name = "Bob"
      expect(ctx.name).to eq("Bob")
    end

    it "returns nil for unknown keys" do
      expect(ctx[:unknown]).to be_nil
    end

    it "raises NoMethodError for undefined method-style access" do
      expect { ctx.does_not_exist }.to raise_error(NoMethodError)
    end

    it "coerces keys to symbols" do
      ctx["nickname"] = "Al"
      expect(ctx[:nickname]).to eq("Al")
    end
  end

  describe "#to_h" do
    it "returns a plain hash copy" do
      h = ctx.to_h
      expect(h).to eq({ name: "Alice", age: 30 })
      h[:name] = "Mutated"
      expect(ctx.name).to eq("Alice")  # original unaffected
    end
  end

  describe "#merge!" do
    it "bulk-sets attributes" do
      ctx.merge!(city: "Paris", age: 31)
      expect(ctx.city).to eq("Paris")
      expect(ctx.age).to  eq(31)
    end

    it "returns self" do
      expect(ctx.merge!(x: 1)).to be(ctx)
    end
  end

  describe "#key?" do
    it "returns true for set attributes" do
      expect(ctx.key?(:name)).to be true
    end

    it "returns false for missing attributes" do
      expect(ctx.key?(:missing)).to be false
    end
  end

  # ── Status ───────────────────────────────────────────────────────────────────

  describe "status" do
    it "starts as success" do
      expect(ctx.success?).to be true
      expect(ctx.ok?).to       be true
      expect(ctx.failure?).to  be false
      expect(ctx.failed?).to   be false
    end
  end

  # ── fail! ─────────────────────────────────────────────────────────────────────

  describe "#fail!" do
    it "marks ctx as failed" do
      ctx.fail! rescue nil
      expect(ctx.failure?).to be true
      expect(ctx.success?).to be false
    end

    it "raises Ctx::Failure" do
      expect { ctx.fail! }.to raise_error(Easyop::Ctx::Failure)
    end

    it "merges attributes before failing" do
      ctx.fail!(error: "Oops", code: 422) rescue nil
      expect(ctx.error).to eq("Oops")
      expect(ctx.code).to  eq(422)
    end

    it "attaches itself to the exception" do
      begin
        ctx.fail!(error: "Boom")
      rescue Easyop::Ctx::Failure => e
        expect(e.ctx).to be(ctx)
        expect(e.message).to include("Boom")
      end
    end
  end

  # ── Error conveniences ────────────────────────────────────────────────────────

  describe "#error / #errors" do
    it "returns nil by default" do
      expect(ctx.error).to  be_nil
      expect(ctx.errors).to eq({})
    end

    it "can be set via error=" do
      ctx.error = "Bad input"
      expect(ctx.error).to eq("Bad input")
    end

    it "can be set via errors=" do
      ctx.errors = { email: "is invalid" }
      expect(ctx.errors[:email]).to eq("is invalid")
    end
  end

  # ── Chainable callbacks ───────────────────────────────────────────────────────

  describe "#on_success / #on_failure" do
    context "when successful" do
      it "yields to on_success" do
        yielded = false
        ctx.on_success { |c| yielded = c }
        expect(yielded).to be(ctx)
      end

      it "does not yield to on_failure" do
        called = false
        ctx.on_failure { called = true }
        expect(called).to be false
      end
    end

    context "when failed" do
      before { ctx.fail! rescue nil }

      it "yields to on_failure" do
        yielded = false
        ctx.on_failure { |c| yielded = c }
        expect(yielded).to be(ctx)
      end

      it "does not yield to on_success" do
        called = false
        ctx.on_success { called = true }
        expect(called).to be false
      end
    end

    it "is chainable" do
      results = []
      ctx
        .on_success { results << :success }
        .on_failure { results << :failure }
      expect(results).to eq([:success])
    end
  end

  # ── Pattern matching ──────────────────────────────────────────────────────────

  describe "#deconstruct_keys" do
    it "includes success/failure status" do
      data = ctx.deconstruct_keys(nil)
      expect(data[:success]).to be true
      expect(data[:failure]).to be false
    end

    it "includes all attributes" do
      data = ctx.deconstruct_keys(nil)
      expect(data[:name]).to eq("Alice")
      expect(data[:age]).to  eq(30)
    end

    it "filters by requested keys" do
      data = ctx.deconstruct_keys([:name, :success])
      expect(data.keys).to match_array([:name, :success])
    end

    it "works with Ruby case/in" do
      result = case ctx
               in { success: true, name: String => n } then "Hello, #{n}"
               in { success: false } then "failed"
               end
      expect(result).to eq("Hello, Alice")
    end
  end

  # ── Rollback ──────────────────────────────────────────────────────────────────

  describe "rollback support" do
    let(:op_a) { double("OpA", rollback: nil) }
    let(:op_b) { double("OpB", rollback: nil) }

    before do
      ctx.called!(op_a)
      ctx.called!(op_b)
    end

    it "calls rollback in reverse order" do
      order = []
      allow(op_b).to receive(:rollback) { order << :b }
      allow(op_a).to receive(:rollback) { order << :a }
      ctx.rollback!
      expect(order).to eq([:b, :a])
    end

    it "does not roll back twice" do
      ctx.rollback!
      ctx.rollback!
      expect(op_a).to have_received(:rollback).once
    end

    it "swallows errors in individual rollbacks" do
      allow(op_b).to receive(:rollback).and_raise("rollback error")
      expect { ctx.rollback! }.not_to raise_error
      expect(op_a).to have_received(:rollback)
    end
  end

  # ── slice ─────────────────────────────────────────────────────────────────────

  describe "#slice" do
    it "returns a hash with only the requested keys" do
      expect(ctx.slice(:name, :age)).to eq({ name: "Alice", age: 30 })
    end

    it "ignores keys that don't exist" do
      expect(ctx.slice(:name, :missing)).to eq({ name: "Alice" })
    end

    it "returns empty hash when no keys match" do
      expect(ctx.slice(:x, :y)).to eq({})
    end
  end

  # ── inspect ───────────────────────────────────────────────────────────────────

  describe "#inspect" do
    it "includes status and attributes" do
      expect(ctx.inspect).to include("Alice")
      expect(ctx.inspect).to include("ok")
    end

    it "shows FAILED when failed" do
      ctx.fail! rescue nil
      expect(ctx.inspect).to include("FAILED")
    end
  end

  # ── respond_to_missing? ───────────────────────────────────────────────────────

  describe "#respond_to_missing?" do
    it "returns true for writer methods (ending with =)" do
      expect(ctx.respond_to?(:anything=)).to be true
    end

    it "returns true for predicate methods (ending with ?)" do
      expect(ctx.respond_to?(:anything?)).to be true
    end

    it "returns true for attributes that exist in ctx" do
      expect(ctx.respond_to?(:name)).to be true
    end

    it "returns false for attributes that do not exist in ctx" do
      expect(ctx.respond_to?(:nonexistent_attribute_xyz)).to be false
    end
  end

  # ── Ctx::Failure message ─────────────────────────────────────────────────────

  describe "Ctx::Failure#message" do
    it "includes the error when ctx.error is set" do
      begin
        ctx.fail!(error: "Something went wrong")
      rescue Easyop::Ctx::Failure => e
        expect(e.message).to eq("Operation failed: Something went wrong")
      end
    end

    it "uses generic message when ctx.error is nil" do
      begin
        ctx.fail!
      rescue Easyop::Ctx::Failure => e
        expect(e.message).to eq("Operation failed")
      end
    end
  end

  # ── called! idempotency ───────────────────────────────────────────────────────

  describe "#called! and #rollback! idempotency" do
    it "called! returns self for chaining" do
      op = double("Op", rollback: nil)
      expect(ctx.called!(op)).to be(ctx)
    end

    it "rollback! is idempotent — second call does not re-rollback" do
      order = []
      op = double("Op")
      allow(op).to receive(:rollback) { order << :called }
      ctx.called!(op)
      ctx.rollback!
      ctx.rollback!
      expect(order.length).to eq(1)
    end
  end
end
