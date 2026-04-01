require "spec_helper"

RSpec.describe Easyop::Operation do
  # ── Minimal operation fixtures ─────────────────────────────────────────────

  let(:noop_op) do
    Class.new do
      include Easyop::Operation
      def call; end
    end
  end

  let(:echo_op) do
    Class.new do
      include Easyop::Operation
      def call
        ctx.output = ctx.input.upcase
      end
    end
  end

  let(:failing_op) do
    Class.new do
      include Easyop::Operation
      def call
        ctx.fail!(error: "nope")
      end
    end
  end

  # ── .call ─────────────────────────────────────────────────────────────────────

  describe ".call" do
    it "returns a Ctx" do
      result = noop_op.call
      expect(result).to be_a(Easyop::Ctx)
    end

    it "passes attributes to ctx" do
      result = echo_op.call(input: "hello")
      expect(result.input).to eq("hello")
      expect(result.output).to eq("HELLO")
    end

    it "returns a successful ctx when call completes" do
      result = noop_op.call
      expect(result.success?).to be true
    end

    it "returns a failed ctx without raising on fail!" do
      result = failing_op.call
      expect(result.failure?).to be true
      expect(result.error).to eq("nope")
    end

    it "accepts a pre-built Ctx" do
      ctx = Easyop::Ctx.new(input: "world")
      result = echo_op.call(ctx)
      expect(result).to be(ctx)
      expect(result.output).to eq("WORLD")
    end
  end

  # ── .call! ────────────────────────────────────────────────────────────────────

  describe ".call!" do
    it "returns ctx on success" do
      result = echo_op.call!(input: "hi")
      expect(result.output).to eq("HI")
    end

    it "raises Ctx::Failure on fail!" do
      expect { failing_op.call! }.to raise_error(Easyop::Ctx::Failure)
    end

    it "attaches ctx to the raised exception" do
      begin
        failing_op.call!
      rescue Easyop::Ctx::Failure => e
        expect(e.ctx.error).to eq("nope")
      end
    end
  end

  # ── ctx access ────────────────────────────────────────────────────────────────

  describe "#ctx" do
    it "is available inside call" do
      inner_ctx = nil
      op = Class.new do
        include Easyop::Operation
        define_method(:call) { inner_ctx = ctx }
      end
      op.call(x: 1)
      expect(inner_ctx).to be_a(Easyop::Ctx)
      expect(inner_ctx.x).to eq(1)
    end
  end

  # ── rollback ──────────────────────────────────────────────────────────────────

  describe "#rollback" do
    it "does nothing by default" do
      op = noop_op.new
      expect { op.rollback }.not_to raise_error
    end
  end

  # ── unhandled exceptions ──────────────────────────────────────────────────────

  describe "unhandled exceptions" do
    let(:boom_op) do
      Class.new do
        include Easyop::Operation
        def call
          raise ArgumentError, "something went wrong"
        end
      end
    end

    it "re-raises unhandled exceptions from .call" do
      expect { boom_op.call }.to raise_error(ArgumentError)
    end

    it "marks ctx as failed before re-raising" do
      op_instance = boom_op.new
      ctx = Easyop::Ctx.new
      expect do
        op_instance._easyop_run(ctx, raise_on_failure: false)
      end.to raise_error(ArgumentError)
      expect(ctx.failure?).to be true
    end
  end

  # ── unhandled exceptions in call! ────────────────────────────────────────────

  describe "unhandled exceptions in call!" do
    let(:boom_op!) do
      Class.new do
        include Easyop::Operation
        def call
          raise ArgumentError, "unhandled in call!"
        end
      end
    end

    it "re-raises unhandled exceptions from .call!" do
      expect { boom_op!.call! }.to raise_error(ArgumentError, "unhandled in call!")
    end

    it "handled exceptions that do not call ctx.fail! allow call! to succeed" do
      op = Class.new do
        include Easyop::Operation
        rescue_from ArgumentError do |e|
          ctx.message = "rescued: #{e.message}"
          # handler does NOT call ctx.fail!, so execution continues cleanly
        end
        def call
          raise ArgumentError, "caught"
        end
      end
      result = op.call!
      expect(result.success?).to be true
      expect(result.message).to eq("rescued: caught")
    end
  end

  # ── inheritance ───────────────────────────────────────────────────────────────

  describe "inheritance" do
    it "subclass inherits parent's rescue handlers" do
      base = Class.new do
        include Easyop::Operation
        rescue_from RuntimeError do |e|
          ctx.fail!(error: "caught: #{e.message}")
        end
      end

      child = Class.new(base) do
        def call
          raise RuntimeError, "boom"
        end
      end

      result = child.call
      expect(result.failure?).to be true
      expect(result.error).to eq("caught: boom")
    end
  end
end
