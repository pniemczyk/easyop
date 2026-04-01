require "spec_helper"

RSpec.describe "skip_if DSL" do
  def make_step(log_key, log, skip_predicate: nil, &call_block)
    Class.new do
      include Easyop::Operation
      skip_if(&skip_predicate) if skip_predicate
      define_method(:call) do
        log << log_key
        instance_exec(&call_block) if call_block
      end
    end
  end

  describe "skip_if on an operation" do
    it "skips the step when predicate returns true" do
      log = []
      step_a = make_step(:a, log)
      step_b = make_step(:b, log, skip_predicate: ->(ctx) { ctx.skip_b? })
      step_c = make_step(:c, log)

      flow = Class.new { include Easyop::Flow; flow step_a, step_b, step_c }
      flow.call(skip_b: true)
      expect(log).to eq([:a, :c])
    end

    it "runs the step when predicate returns false" do
      log = []
      step_a = make_step(:a, log)
      step_b = make_step(:b, log, skip_predicate: ->(ctx) { ctx.skip_b? })

      flow = Class.new { include Easyop::Flow; flow step_a, step_b }
      flow.call(skip_b: false)
      expect(log).to eq([:a, :b])
    end

    it "runs all steps when no skip_if declared" do
      log = []
      step_a = make_step(:a, log)
      step_b = make_step(:b, log)

      flow = Class.new { include Easyop::Flow; flow step_a, step_b }
      flow.call
      expect(log).to eq([:a, :b])
    end

    it "does not add a skipped step to rollback list" do
      rollback_log = []
      step_a = Class.new do
        include Easyop::Operation
        define_method(:call) {}
        define_method(:rollback) { rollback_log << :a }
      end
      step_b = Class.new do
        include Easyop::Operation
        skip_if { |_ctx| true }  # always skip
        define_method(:call) { rollback_log << :b_called }
        define_method(:rollback) { rollback_log << :b_rollback }
      end
      step_c = Class.new do
        include Easyop::Operation
        define_method(:call) { ctx.fail!(error: "c failed") }
      end

      flow = Class.new { include Easyop::Flow; flow step_a, step_b, step_c }
      flow.call
      # b was skipped entirely, so only a should roll back
      expect(rollback_log).to eq([:a])
    end

    it "works with the ctx.coupon_code? predicate pattern" do
      log = []
      apply_coupon = Class.new do
        include Easyop::Operation
        skip_if { |ctx| !ctx.coupon_code? || ctx.coupon_code.to_s.empty? }
        define_method(:call) { log << :coupon_applied }
      end

      flow = Class.new { include Easyop::Flow; flow apply_coupon }

      flow.call(coupon_code: "SAVE10")
      expect(log).to eq([:coupon_applied])

      log.clear
      flow.call
      expect(log).to eq([])
    end
  end

  describe "skip_if on a plain operation (no flow)" do
    it "does not affect .call (skip_if is a Flow concept)" do
      # skip_if is evaluated by the Flow runner — calling an operation directly
      # bypasses the skip check. This is intentional: skip_if is a flow concern.
      log = []
      op = Class.new do
        include Easyop::Operation
        skip_if { |_ctx| true }
        define_method(:call) { log << :ran }
      end

      op.call
      expect(log).to eq([:ran])
    end
  end

  describe "_skip_predicate" do
    it "returns nil when no skip_if is declared" do
      op = Class.new { include Easyop::Operation }
      expect(op._skip_predicate).to be_nil
    end

    it "returns the block when skip_if is declared" do
      predicate = ->(ctx) { ctx.skip? }
      op = Class.new do
        include Easyop::Operation
      end
      op.skip_if(&predicate)
      expect(op._skip_predicate).not_to be_nil
      expect(op._skip_predicate).to be_a(Proc)
    end
  end
end
