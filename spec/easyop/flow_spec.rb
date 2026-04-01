require "spec_helper"

RSpec.describe Easyop::Flow do
  # ── Helper: log-recording operation factory ───────────────────────────────────
  def make_step(name, log, &blk)
    n = name
    l = log
    Class.new do
      include Easyop::Operation
      define_method(:call) { l << n; blk ? instance_exec(&blk) : nil }
    end
  end

  # ── Basic flow ────────────────────────────────────────────────────────────────

  describe "basic sequential execution" do
    it "runs steps in order, sharing ctx" do
      log = []
      step_a = make_step(:a, log) { ctx.a_done = true }
      step_b = make_step(:b, log) { ctx.b_done = true }
      step_c = make_step(:c, log)

      flow_op = Class.new do
        include Easyop::Flow
        flow step_a, step_b, step_c
      end

      result = flow_op.call
      expect(log).to eq([:a, :b, :c])
      expect(result.a_done).to be true
      expect(result.b_done).to be true
    end

    it "passes initial attributes to ctx" do
      step = Class.new do
        include Easyop::Operation
        def call; ctx.output = ctx.input * 2; end
      end

      flow_op = Class.new do
        include Easyop::Flow
        flow step
      end

      expect(flow_op.call(input: 7).output).to eq(14)
    end
  end

  # ── Failure halts execution ───────────────────────────────────────────────────

  describe "failure handling" do
    it "halts on step failure" do
      log = []
      step_a = make_step(:a, log) { ctx.fail!(error: "step_a failed") }
      step_b = make_step(:b, log)

      flow_op = Class.new do
        include Easyop::Flow
        flow step_a, step_b
      end

      result = flow_op.call
      expect(result.failure?).to be true
      expect(result.error).to    eq("step_a failed")
      expect(log).to             eq([:a])
    end

    it "returns a failed ctx without raising (.call)" do
      step = Class.new { include Easyop::Operation; def call; ctx.fail!; end }
      flow_op = Class.new { include Easyop::Flow; flow step }

      expect { flow_op.call }.not_to raise_error
      expect(flow_op.call.failure?).to be true
    end

    it "raises Ctx::Failure on .call!" do
      step = Class.new { include Easyop::Operation; def call; ctx.fail!; end }
      flow_op = Class.new { include Easyop::Flow; flow step }

      expect { flow_op.call! }.to raise_error(Easyop::Ctx::Failure)
    end
  end

  # ── Rollback ──────────────────────────────────────────────────────────────────

  describe "rollback on failure" do
    it "calls rollback in reverse order on failure" do
      rollback_log = []

      step_a = Class.new do
        include Easyop::Operation
        def call;     end
        define_method(:rollback) { rollback_log << :a }
      end

      step_b = Class.new do
        include Easyop::Operation
        def call;     end
        define_method(:rollback) { rollback_log << :b }
      end

      step_c = Class.new do
        include Easyop::Operation
        def call; ctx.fail!(error: "c failed"); end
        define_method(:rollback) { rollback_log << :c }
      end

      flow_op = Class.new do
        include Easyop::Flow
        flow step_a, step_b, step_c
      end

      flow_op.call
      # c failed before completing, b and a already ran → roll back b, a
      expect(rollback_log).to eq([:b, :a])
    end

    it "swallows rollback errors" do
      step_a = Class.new do
        include Easyop::Operation
        def call; end
        def rollback; raise "rollback exploded"; end
      end
      step_b = Class.new do
        include Easyop::Operation
        def call; ctx.fail!; end
      end

      flow_op = Class.new { include Easyop::Flow; flow step_a, step_b }
      expect { flow_op.call }.not_to raise_error
    end
  end

  # ── Conditional steps (guards) ────────────────────────────────────────────────

  describe "conditional steps via lambda guards" do
    it "skips a step when guard returns false" do
      log = []
      step_a = make_step(:a, log)
      step_b = make_step(:b, log)  # guarded
      step_c = make_step(:c, log)

      flow_op = Class.new do
        include Easyop::Flow
        flow step_a, ->(ctx) { ctx.run_b? }, step_b, step_c
      end

      result = flow_op.call(run_b: false)
      expect(log).to eq([:a, :c])
    end

    it "runs a guarded step when guard returns truthy" do
      log = []
      step_a = make_step(:a, log)
      step_b = make_step(:b, log)

      flow_op = Class.new do
        include Easyop::Flow
        flow step_a, ->(ctx) { ctx.run_b? }, step_b
      end

      flow_op.call(run_b: true)
      expect(log).to eq([:a, :b])
    end
  end

  # ── Flow composition ──────────────────────────────────────────────────────────

  describe "nested flows" do
    it "supports a flow as a step inside another flow" do
      log = []
      step_a = make_step(:a, log)
      step_b = make_step(:b, log)
      step_c = make_step(:c, log)

      inner_flow = Class.new do
        include Easyop::Flow
        flow step_b, step_c
      end

      outer_flow = Class.new do
        include Easyop::Flow
        flow step_a, inner_flow
      end

      outer_flow.call
      expect(log).to eq([:a, :b, :c])
    end
  end

  # ── ctx.on_success / on_failure chaining ─────────────────────────────────────

  describe "result callbacks" do
    it "chains on_success on flow success" do
      step = make_step(:a, []) { ctx.value = 42 }
      flow_op = Class.new { include Easyop::Flow; flow step }

      received = nil
      flow_op.call.on_success { |ctx| received = ctx.value }
      expect(received).to eq(42)
    end

    it "chains on_failure on flow failure" do
      step = Class.new { include Easyop::Operation; def call; ctx.fail!(error: "x"); end }
      flow_op = Class.new { include Easyop::Flow; flow step }

      received = nil
      flow_op.call.on_failure { |ctx| received = ctx.error }
      expect(received).to eq("x")
    end
  end
end
