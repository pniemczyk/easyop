require "spec_helper"
require "easyop/plugins/transactional"

RSpec.describe Easyop::Plugins::Transactional do
  # ── Stubs ──────────────────────────────────────────────────────────────────

  # Minimal AR stub: records whether transaction was called
  before do
    stub_const("ActiveRecord::Base", Class.new do
      @transaction_calls = 0
      class << self
        attr_reader :transaction_calls
        def transaction(&block)
          @transaction_calls += 1
          block.call
        end
        def reset!; @transaction_calls = 0; end
      end
    end)
  end

  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      include Easyop::Plugins::Transactional
      class_eval(&blk) if blk
    end
  end

  # ── include style ──────────────────────────────────────────────────────────

  describe "include style" do
    it "wraps call in a transaction" do
      op = make_op { def call; ctx.result = "done"; end }
      op.call
      expect(ActiveRecord::Base.transaction_calls).to eq(1)
    end

    it "the call result is accessible after the transaction" do
      op = make_op { def call; ctx.result = "value"; end }
      result = op.call
      expect(result.result).to eq("value")
    end

    it "transaction rolls back (Ctx::Failure propagates through block) on fail!" do
      rolled_back_ref = [false]
      ar_stub = Class.new
      ar_stub.define_singleton_method(:transaction) do |&blk|
        blk.call
      rescue Easyop::Ctx::Failure
        rolled_back_ref[0] = true
        raise
      end
      stub_const("ActiveRecord::Base", ar_stub)
      op = make_op { def call; ctx.fail!(error: "bad"); end }
      result = op.call
      expect(result.failure?).to be true
      expect(rolled_back_ref[0]).to be true
    end

    it "ctx.fail! still results in a failed ctx (swallowed by .call)" do
      op = make_op { def call; ctx.fail!(error: "tx failed"); end }
      result = op.call
      expect(result.failure?).to be true
      expect(result.error).to eq("tx failed")
    end
  end

  # ── plugin DSL style ───────────────────────────────────────────────────────

  describe "plugin DSL style" do
    it "can be installed via plugin DSL" do
      op = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Transactional
        def call; ctx.result = "plugin"; end
      end
      op.call
      expect(ActiveRecord::Base.transaction_calls).to eq(1)
    end

    it "registers in _registered_plugins" do
      op = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Transactional
      end
      expect(op._registered_plugins.map { |p| p[:plugin] }).to include(Easyop::Plugins::Transactional)
    end
  end

  # ── transactional false ────────────────────────────────────────────────────

  describe "transactional false" do
    it "skips the transaction when disabled" do
      op = make_op do
        transactional false
        def call; ctx.result = "no tx"; end
      end
      op.call
      expect(ActiveRecord::Base.transaction_calls).to eq(0)
    end

    it "subclass can disable when parent has it enabled" do
      parent = make_op { def call; ctx.result = "parent"; end }
      child  = Class.new(parent) do
        transactional false
        def call; ctx.result = "child"; end
      end
      child.call
      expect(ActiveRecord::Base.transaction_calls).to eq(0)
    end

    it "subclass inherits enabled state from parent" do
      parent = make_op { def call; end }
      child  = Class.new(parent) { def call; ctx.result = "inherited"; end }
      child.call
      expect(ActiveRecord::Base.transaction_calls).to eq(1)
    end
  end

  # ── inheritance ────────────────────────────────────────────────────────────

  describe "inheritance" do
    it "subclass also wraps in transaction" do
      parent = make_op
      child  = Class.new(parent) { def call; ctx.x = 1; end }
      child.call
      expect(ActiveRecord::Base.transaction_calls).to eq(1)
    end

    it "parent is not affected by subclass transactional false" do
      parent = make_op { def call; ctx.result = "parent"; end }
      child  = Class.new(parent) { transactional false }
      parent.call
      expect(ActiveRecord::Base.transaction_calls).to eq(1)
    end
  end

  # ── Sequel support ─────────────────────────────────────────────────────────

  describe "Sequel adapter" do
    it "uses Sequel::Model.db.transaction when ActiveRecord is not defined" do
      sequel_tx_count = 0
      sequel_db = Object.new
      sequel_db.define_singleton_method(:transaction) { |&blk| sequel_tx_count += 1; blk.call }

      hide_const("ActiveRecord")
      stub_const("Sequel::Model", Module.new { define_singleton_method(:db) { sequel_db } })

      op = Class.new do
        include Easyop::Operation
        include Easyop::Plugins::Transactional
        def call; ctx.result = "sequel"; end
      end
      op.call
      expect(sequel_tx_count).to eq(1)
    end
  end

  # ── No adapter ─────────────────────────────────────────────────────────────

  describe "no adapter available" do
    it "raises a descriptive error" do
      hide_const("ActiveRecord")
      begin
        hide_const("Sequel")
      rescue NameError
        # Sequel not defined — that's fine
      end

      op = Class.new do
        include Easyop::Operation
        include Easyop::Plugins::Transactional
        def call; ctx.result = "never"; end
      end
      expect { op.call }.to raise_error(RuntimeError, /requires ActiveRecord or Sequel/)
    end
  end

  # ── works alongside other hooks ────────────────────────────────────────────

  describe "integration with before/after hooks" do
    it "before hook runs inside the transaction" do
      order = []
      ar_stub = Class.new
      ar_stub.define_singleton_method(:transaction) do |&blk|
        order << :tx_open
        blk.call
        order << :tx_close
      end
      stub_const("ActiveRecord::Base", ar_stub)
      captured_order = order
      op = make_op do
        before { captured_order << :before }
        after  { captured_order << :after }
        define_method(:call) { captured_order << :call }
      end
      op.call
      expect(order).to eq([:tx_open, :before, :call, :after, :tx_close])
    end
  end
end
