require "spec_helper"

RSpec.describe Easyop::FlowBuilder do
  def make_flow(result_value: nil, fail_with: nil)
    step = if fail_with
      Class.new do
        include Easyop::Operation
        define_method(:call) { ctx.fail!(error: fail_with) }
      end
    else
      rv = result_value
      Class.new do
        include Easyop::Operation
        define_method(:call) { ctx.result = rv }
      end
    end

    Class.new { include Easyop::Flow; flow step }
  end

  describe ".prepare" do
    it "returns a FlowBuilder" do
      flow_class = make_flow(result_value: 42)
      expect(flow_class.prepare).to be_a(Easyop::FlowBuilder)
    end

    it "returns a new builder each time" do
      flow_class = make_flow(result_value: 42)
      expect(flow_class.prepare).not_to be(flow_class.prepare)
    end
  end

  describe "#on_success" do
    it "fires the callback when the flow succeeds" do
      received = nil
      make_flow(result_value: 99)
        .prepare
        .on_success { |ctx| received = ctx.result }
        .call

      expect(received).to eq(99)
    end

    it "does not fire on failure" do
      received = :not_called
      make_flow(fail_with: "boom")
        .prepare
        .on_success { |ctx| received = ctx.result }
        .call

      expect(received).to eq(:not_called)
    end

    it "is chainable — multiple on_success callbacks run in order" do
      log = []
      make_flow(result_value: 1)
        .prepare
        .on_success { log << :first }
        .on_success { log << :second }
        .call

      expect(log).to eq([:first, :second])
    end
  end

  describe "#on_failure" do
    it "fires the callback when the flow fails" do
      received = nil
      make_flow(fail_with: "something broke")
        .prepare
        .on_failure { |ctx| received = ctx.error }
        .call

      expect(received).to eq("something broke")
    end

    it "does not fire on success" do
      received = :not_called
      make_flow(result_value: 1)
        .prepare
        .on_failure { received = :called }
        .call

      expect(received).to eq(:not_called)
    end

    it "is chainable — multiple on_failure callbacks run in order" do
      log = []
      make_flow(fail_with: "oops")
        .prepare
        .on_failure { log << :first }
        .on_failure { log << :second }
        .call

      expect(log).to eq([:first, :second])
    end
  end

  describe "mixed on_success / on_failure chaining" do
    it "fires only success callbacks on success" do
      success_log = []
      failure_log = []

      make_flow(result_value: 7)
        .prepare
        .on_success { |ctx| success_log << ctx.result }
        .on_failure { |ctx| failure_log << ctx.error }
        .call

      expect(success_log).to eq([7])
      expect(failure_log).to eq([])
    end

    it "fires only failure callbacks on failure" do
      success_log = []
      failure_log = []

      make_flow(fail_with: "bad")
        .prepare
        .on_success { |ctx| success_log << ctx.result }
        .on_failure { |ctx| failure_log << ctx.error }
        .call

      expect(success_log).to eq([])
      expect(failure_log).to eq(["bad"])
    end
  end

  describe "#call" do
    it "returns the ctx" do
      ctx = make_flow(result_value: 42).prepare.call
      expect(ctx).to be_a(Easyop::Ctx)
      expect(ctx.result).to eq(42)
    end

    it "accepts initial attributes" do
      step = Class.new do
        include Easyop::Operation
        def call; ctx.output = ctx.input * 3; end
      end
      flow_class = Class.new { include Easyop::Flow; flow step }
      ctx = flow_class.prepare.call(input: 5)
      expect(ctx.output).to eq(15)
    end
  end

  describe "#bind_with and #on" do
    it "calls a success method on the bound object with ctx" do
      received = nil
      target   = Object.new
      target.define_singleton_method(:handle_success) { |ctx| received = ctx.result }

      make_flow(result_value: 55)
        .prepare
        .bind_with(target)
        .on(success: :handle_success)
        .call

      expect(received).to eq(55)
    end

    it "calls a fail method on the bound object with ctx" do
      received = nil
      target   = Object.new
      target.define_singleton_method(:handle_failure) { |ctx| received = ctx.error }

      make_flow(fail_with: "oops")
        .prepare
        .bind_with(target)
        .on(fail: :handle_failure)
        .call

      expect(received).to eq("oops")
    end

    it "calls zero-arity methods without passing ctx" do
      called = false
      target = Object.new
      target.define_singleton_method(:handle_success) { called = true }

      make_flow(result_value: 1)
        .prepare
        .bind_with(target)
        .on(success: :handle_success)
        .call

      expect(called).to be true
    end

    it "raises ArgumentError when no bound object and using .on" do
      expect do
        make_flow(result_value: 1)
          .prepare
          .on(success: :some_method)
          .call
      end.to raise_error(ArgumentError, /bind_with/)
    end

    it "supports both success: and fail: in a single .on call" do
      success_received = nil
      fail_received    = nil
      target = Object.new
      target.define_singleton_method(:on_ok)   { |ctx| success_received = ctx.result }
      target.define_singleton_method(:on_fail) { |ctx| fail_received    = ctx.error }

      make_flow(result_value: 7).prepare.bind_with(target).on(success: :on_ok, fail: :on_fail).call
      expect(success_received).to eq(7)
      expect(fail_received).to be_nil

      make_flow(fail_with: "err").prepare.bind_with(target).on(success: :on_ok, fail: :on_fail).call
      expect(fail_received).to eq("err")
    end
  end

  describe "ctx.slice" do
    it "returns a hash with only the requested keys" do
      ctx = Easyop::Ctx.new(name: "Alice", email: "alice@example.com", age: 30)
      expect(ctx.slice(:name, :email)).to eq({ name: "Alice", email: "alice@example.com" })
    end

    it "excludes keys not in the request" do
      ctx = Easyop::Ctx.new(name: "Alice", age: 30)
      expect(ctx.slice(:name)).to eq({ name: "Alice" })
    end

    it "ignores keys that don't exist" do
      ctx = Easyop::Ctx.new(name: "Alice")
      expect(ctx.slice(:name, :missing)).to eq({ name: "Alice" })
    end

    it "returns empty hash when no keys match" do
      ctx = Easyop::Ctx.new(name: "Alice")
      expect(ctx.slice(:x, :y)).to eq({})
    end
  end
end
