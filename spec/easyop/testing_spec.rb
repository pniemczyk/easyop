# frozen_string_literal: true

# Minimal AR / ActiveJob stubs — no gems required
module ActiveRecord
  class Base; end
end unless defined?(ActiveRecord)

module ActiveJob
  class Base
    def self.queue_as(_); end
    def self.set(**); JobBuilder.new(self, {}); end
    def self.perform_later(*); end
  end
  class JobBuilder
    def initialize(klass, opts); @klass = klass; @opts = opts; end
    def set(**); self; end
    def perform_later(*); end
  end
end unless defined?(ActiveJob)

class Time
  def self.current = now
end unless Time.respond_to?(:current)

require "spec_helper"
require "easyop/testing"
require "easyop/plugins/async"
require "easyop/plugins/events"
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/recording"
require "easyop/simple_crypt"

RSpec.describe Easyop::Testing do
  include Easyop::Testing

  let(:success_op) { Class.new { include Easyop::Operation } }
  let(:failure_op) do
    Class.new do
      include Easyop::Operation
      def call = ctx.fail!(error: "Something went wrong")
    end
  end

  # ── op_call / op_call! ────────────────────────────────────────────────────────

  describe "#op_call" do
    it "returns a Ctx" do
      expect(op_call(success_op)).to be_a(Easyop::Ctx)
    end

    it "does not raise on failure" do
      expect { op_call(failure_op) }.not_to raise_error
    end

    it "passes attrs to the operation" do
      op = Class.new do
        include Easyop::Operation
        def call = (ctx[:out] = ctx[:n] * 2)
      end
      expect(op_call(op, n: 5)[:out]).to eq(10)
    end
  end

  describe "#op_call!" do
    it "raises Ctx::Failure on failure" do
      expect { op_call!(failure_op) }.to raise_error(Easyop::Ctx::Failure)
    end

    it "returns Ctx on success" do
      expect(op_call!(success_op)).to be_a(Easyop::Ctx)
    end
  end

  # ── assert_op_success / assert_op_failure ─────────────────────────────────────

  describe "#assert_op_success" do
    it "passes for a successful ctx" do
      expect { assert_op_success(success_op.call) }.not_to raise_error
    end

    it "raises for a failed ctx and includes the error" do
      op  = Class.new { include Easyop::Operation; def call = ctx.fail!(error: "broke") }
      expect { assert_op_success(op.call) }.to raise_error(/broke/)
    end
  end

  describe "#assert_op_failure" do
    it "passes for a failed ctx" do
      expect { assert_op_failure(failure_op.call) }.not_to raise_error
    end

    it "raises for a successful ctx" do
      expect { assert_op_failure(success_op.call) }.to raise_error(/succeed/)
    end

    it "checks an exact error string" do
      op  = Class.new { include Easyop::Operation; def call = ctx.fail!(error: "Insufficient credits") }
      expect { assert_op_failure(op.call, error: "Insufficient credits") }.not_to raise_error
    end

    it "raises when the error string does not match" do
      expect { assert_op_failure(failure_op.call, error: "Different error") }.to raise_error(RuntimeError)
    end

    it "matches a regexp against the error" do
      op  = Class.new { include Easyop::Operation; def call = ctx.fail!(error: "Insufficient credits") }
      expect { assert_op_failure(op.call, error: /insufficient/i) }.not_to raise_error
    end
  end

  describe "#assert_ctx_has" do
    it "passes when all key-values match" do
      op  = Class.new { include Easyop::Operation; def call = (ctx[:x] = 1; ctx[:y] = 2) }
      expect { assert_ctx_has(op.call, x: 1, y: 2) }.not_to raise_error
    end

    it "raises when a value does not match — message includes expected and got" do
      op  = Class.new { include Easyop::Operation; def call = (ctx[:x] = 1) }
      expect { assert_ctx_has(op.call, x: 99) }.to raise_error(/expected.*got/im)
    end
  end

  # ── stub_op — uses RSpec allow().to receive() ─────────────────────────────────
  # Stubs are scoped to the block (restored via and_call_original after yield).

  describe "#stub_op" do
    it "stubs .call to return a successful ctx" do
      stub_op(success_op) do
        expect(success_op.call(anything: true)).to be_success
      end
    end

    it "stubs .call to return a failed ctx when success: false" do
      stub_op(success_op, success: false) do
        expect(success_op.call).to be_failure
      end
    end

    it "sets the error attribute when success: false with error:" do
      stub_op(success_op, success: false, error: "Custom error") do
        expect(success_op.call.error).to eq("Custom error")
      end
    end

    it "stubs .call! to raise Ctx::Failure when success: false" do
      stub_op(success_op, success: false) do
        expect { success_op.call! }.to raise_error(Easyop::Ctx::Failure)
      end
    end

    it "stubs .call! to return ctx when success: true" do
      stub_op(success_op) do
        expect(success_op.call!).to be_success
      end
    end

    it "restores original behaviour after the block" do
      op = Class.new { include Easyop::Operation; def call = (ctx[:ran] = true) }
      stub_op(op, success: false) { }
      expect(op.call[:ran]).to be(true)
    end

    it "exposes extra ctx_attrs on the stubbed ctx" do
      stub_op(success_op, user_id: 42) do
        expect(success_op.call[:user_id]).to eq(42)
      end
    end
  end

  # ── async helpers ─────────────────────────────────────────────────────────────
  # call_async spy uses thread-locals so no ActiveJob is needed in capture/inline modes.

  describe "#capture_async / #perform_async_inline" do
    let(:async_op) do
      Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Async
        def call = (ctx[:done] = true)
      end
    end

    describe "#capture_async" do
      it "captures call_async invocations without enqueuing" do
        calls = capture_async { async_op.call_async(email: "a@b.com") }
        expect(calls.size).to eq(1)
        expect(calls.first[:operation]).to eq(async_op)
      end

      it "captures attrs" do
        calls = capture_async { async_op.call_async(email: "a@b.com") }
        expect(calls.first[:attrs]).to include(email: "a@b.com")
      end

      it "does not call the operation" do
        called = false
        op = Class.new do
          include Easyop::Operation
          plugin Easyop::Plugins::Async
          define_method(:call) { called = true }
        end
        capture_async { op.call_async }
        expect(called).to be(false)
      end
    end

    describe "#assert_async_enqueued" do
      it "passes when the operation was captured" do
        calls = capture_async { async_op.call_async }
        expect { assert_async_enqueued(calls, async_op) }.not_to raise_error
      end

      it "raises when the operation was not captured" do
        expect { assert_async_enqueued([], async_op) }.to raise_error(RuntimeError)
      end

      it "verifies attrs subset" do
        calls = capture_async { async_op.call_async(n: 1) }
        expect { assert_async_enqueued(calls, async_op, with: { n: 1 }) }.not_to raise_error
        expect { assert_async_enqueued(calls, async_op, with: { n: 99 }) }.to raise_error(RuntimeError)
      end
    end

    describe "#assert_no_async_enqueued" do
      it "passes when nothing was captured" do
        expect { assert_no_async_enqueued([]) }.not_to raise_error
      end

      it "raises when something was captured" do
        calls = capture_async { async_op.call_async }
        expect { assert_no_async_enqueued(calls) }.to raise_error(RuntimeError)
      end
    end

    describe "#perform_async_inline" do
      it "executes the operation synchronously" do
        called = false
        op = Class.new do
          include Easyop::Operation
          plugin Easyop::Plugins::Async
          define_method(:call) { called = true }
        end
        perform_async_inline { op.call_async }
        expect(called).to be(true)
      end
    end
  end

  # ── event helpers ─────────────────────────────────────────────────────────────

  describe "#capture_events / event assertions" do
    let(:bus) { Easyop::Events::Bus::Memory.new }

    let(:event_op) do
      b = bus
      Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Events, bus: b
        emits "order.placed", on: :success, payload: ->(ctx) { { order_id: ctx[:order_id] } }
        def call = (ctx[:order_id] = 99)
      end
    end

    it "captures emitted events" do
      events = capture_events(bus) { event_op.call }
      expect(events.size).to eq(1)
    end

    describe "#assert_event_emitted" do
      it "passes when the event was emitted" do
        events = capture_events(bus) { event_op.call }
        expect { assert_event_emitted(events, "order.placed") }.not_to raise_error
      end

      it "raises when the event was not emitted" do
        expect { assert_event_emitted([], "order.placed") }.to raise_error(RuntimeError)
      end
    end

    describe "#assert_no_events" do
      it "passes when no events were emitted" do
        expect { assert_no_events([]) }.not_to raise_error
      end

      it "raises when events were emitted" do
        events = capture_events(bus) { event_op.call }
        expect { assert_no_events(events) }.to raise_error(RuntimeError)
      end
    end

    describe "#assert_event_payload" do
      it "passes when payload matches" do
        events = capture_events(bus) { event_op.call }
        expect { assert_event_payload(events, "order.placed", order_id: 99) }.not_to raise_error
      end

      it "raises when payload does not match" do
        events = capture_events(bus) { event_op.call }
        expect { assert_event_payload(events, "order.placed", order_id: 0) }.to raise_error(RuntimeError)
      end
    end

    describe "#assert_event_source" do
      it "matches by source class name" do
        events = capture_events(bus) { event_op.call }
        # anonymous class has no name; just verify the assertion doesn't raise
        # when a non-existent source is checked it DOES raise
        expect { assert_event_source(events, "order.placed", "NONEXISTENT") }.to raise_error(RuntimeError)
      end
    end
  end

  # ── recording helpers ─────────────────────────────────────────────────────────
  # Recording plugin skips anonymous classes; give the op a named identity.

  describe "recording assertions with FakeModel" do
    before { Easyop.configure { |c| c.recording_secret = "a" * 32 } }

    let(:model) { Easyop::Testing::FakeModel.new }

    let(:recording_op) do
      m = model
      klass = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Recording, model: m
        filter_params :password
        encrypt_params :credit_card_number
        record_result attrs: %i[user_id]
        def call = (ctx[:user_id] = 42)
      end
      # Recording plugin skips anonymous classes (self.class.name == nil).
      klass.define_singleton_method(:name) { "TestRecordingOp" }
      klass
    end

    subject do
      recording_op.call(email: "a@b.com", password: "secret", credit_card_number: "4242")
    end

    before { subject }

    it "writes a record to the model" do
      expect(model.last).not_to be_nil
    end

    it "filters sensitive params" do
      expect { assert_params_filtered(model, :password) }.not_to raise_error
    end

    it "encrypts designated params" do
      expect { assert_params_encrypted(model, :credit_card_number) }.not_to raise_error
    end

    it "records a plain param" do
      expect { assert_params_recorded(model, :email, "a@b.com") }.not_to raise_error
    end

    it "records result attrs" do
      expect { assert_result_recorded(model, :user_id, 42) }.not_to raise_error
    end

    it "round-trips encrypted params via decrypt_recorded_param" do
      expect(decrypt_recorded_param(model, :credit_card_number)).to eq("4242")
    end

    it "reports recorded success" do
      expect { assert_recorded_success(model) }.not_to raise_error
    end
  end
end
