# Minimal ActiveSupport::Notifications stub — no gem required
module ActiveSupport
  module Notifications
    class Event
      attr_reader :name, :payload

      def initialize(name, started, finished, _id, payload)
        @name     = name
        @started  = started
        @finished = finished
        @payload  = payload
      end

      def duration
        ((@finished - @started) * 1000.0)
      end
    end

    class << self
      def _subscribers
        @_subscribers ||= Hash.new { |h, k| h[k] = [] }
      end

      def subscribe(name, &block)
        _subscribers[name] << block
      end

      def instrument(name, payload = {})
        started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result   = block_given? ? yield(payload) : nil
        finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        _subscribers[name].each { |s| s.call(name, started, finished, "id", payload) }
        result
      end

      def reset!
        @_subscribers = nil
      end
    end
  end
end

require "spec_helper"
require "easyop/plugins/instrumentation"

RSpec.describe Easyop::Plugins::Instrumentation do
  EVENT = Easyop::Plugins::Instrumentation::EVENT

  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      class_eval(&blk) if blk
    end
  end

  before { ActiveSupport::Notifications.reset! }

  # ── install ──────────────────────────────────────────────────────────────────

  describe ".install" do
    it "prepends RunWrapper onto the operation class" do
      op = make_op { def call; end }
      op.plugin(Easyop::Plugins::Instrumentation)
      expect(op.ancestors).to include(Easyop::Plugins::Instrumentation::RunWrapper)
    end
  end

  # ── successful call ──────────────────────────────────────────────────────────

  describe "successful call" do
    let(:op) do
      make_op { def call; ctx.output = "done"; end }.tap do |klass|
        klass.plugin(Easyop::Plugins::Instrumentation)
      end
    end

    let(:captured) { [] }

    before do
      ActiveSupport::Notifications.subscribe(EVENT) { |*args| captured << args }
    end

    it "fires the event after a successful call" do
      op.call
      expect(captured.length).to eq(1)
    end

    it "payload has :success => true" do
      op.call
      payload = captured.last[4]
      expect(payload[:success]).to be true
    end

    it "payload has :error => nil" do
      op.call
      payload = captured.last[4]
      expect(payload[:error]).to be_nil
    end

    it "payload has :operation set to the class name" do
      # stub_const needed because anonymous class has no name
      stub_const("InstrumentedSuccessOp", op)
      InstrumentedSuccessOp.call
      payload = captured.last[4]
      expect(payload[:operation]).to eq("InstrumentedSuccessOp")
    end

    it "payload :duration is a non-negative Float" do
      op.call
      payload = captured.last[4]
      expect(payload[:duration]).to be_a(Float)
      expect(payload[:duration]).to be >= 0
    end

    it "payload :ctx is the actual Ctx object" do
      result = op.call
      payload = captured.last[4]
      expect(payload[:ctx]).to be_a(Easyop::Ctx)
      expect(payload[:ctx]).to be(result)
    end
  end

  # ── failed call (ctx.fail!) ──────────────────────────────────────────────────

  describe "failed call via ctx.fail!" do
    let(:op) do
      make_op { def call; ctx.fail!(error: "something broke"); end }.tap do |klass|
        klass.plugin(Easyop::Plugins::Instrumentation)
      end
    end

    let(:captured) { [] }

    before do
      ActiveSupport::Notifications.subscribe(EVENT) { |*args| captured << args }
    end

    it "fires the event even when ctx.fail! is called" do
      op.call
      expect(captured.length).to eq(1)
    end

    it "payload has :success => false" do
      op.call
      payload = captured.last[4]
      expect(payload[:success]).to be false
    end

    it "payload has :error set to the error message" do
      op.call
      payload = captured.last[4]
      expect(payload[:error]).to eq("something broke")
    end

    it "payload :duration is still a positive number" do
      op.call
      payload = captured.last[4]
      expect(payload[:duration]).to be > 0
    end
  end

  # ── inheritance ──────────────────────────────────────────────────────────────

  describe "plugin installed on parent propagates to subclasses" do
    let(:parent) do
      make_op { def call; end }.tap do |klass|
        klass.plugin(Easyop::Plugins::Instrumentation)
      end
    end

    let(:child) do
      Class.new(parent) { def call; ctx.child_ran = true; end }
    end

    let(:captured) { [] }

    before do
      ActiveSupport::Notifications.subscribe(EVENT) { |*args| captured << args }
    end

    it "subclass calls also fire the event" do
      child.call
      expect(captured.length).to eq(1)
    end

    it "subclass call payload has :success => true" do
      child.call
      payload = captured.last[4]
      expect(payload[:success]).to be true
    end
  end

  # ── multiple operations ──────────────────────────────────────────────────────

  describe "multiple operations with separate plugin installs" do
    let(:captured) { [] }

    before do
      ActiveSupport::Notifications.subscribe(EVENT) { |*args| captured << args }
    end

    it "each fires a separate event with its own :operation name" do
      op_a = make_op { def call; end }
      op_b = make_op { def call; end }
      stub_const("InstrumentOpA", op_a)
      stub_const("InstrumentOpB", op_b)

      op_a.plugin(Easyop::Plugins::Instrumentation)
      op_b.plugin(Easyop::Plugins::Instrumentation)

      op_a.call
      op_b.call

      expect(captured.length).to eq(2)
      names = captured.map { |args| args[4][:operation] }
      expect(names).to include("InstrumentOpA", "InstrumentOpB")
    end
  end

  # ── attach_log_subscriber ────────────────────────────────────────────────────

  describe ".attach_log_subscriber" do
    let(:fake_logger) do
      logger = Object.new
      logger.instance_variable_set(:@infos, [])
      logger.instance_variable_set(:@warns, [])
      logger.define_singleton_method(:infos) { @infos }
      logger.define_singleton_method(:warns) { @warns }
      logger.define_singleton_method(:info)  { |msg| @infos << msg }
      logger.define_singleton_method(:warn)  { |msg| @warns << msg }
      logger
    end

    let(:op_success) do
      make_op { def call; end }.tap { |k| k.plugin(Easyop::Plugins::Instrumentation) }
    end

    let(:op_failure) do
      make_op { def call; ctx.fail!(error: "oops"); end }.tap do |k|
        k.plugin(Easyop::Plugins::Instrumentation)
      end
    end

    it "logs info on success" do
      fl = fake_logger
      rails_mod = Module.new do
        define_singleton_method(:logger) { fl }
        def self.respond_to?(m, *inc_priv); m == :logger || super; end
      end
      stub_const("Rails", rails_mod)
      # Give the op a constant name so the subscriber doesn't skip it
      stub_const("LogSubscriberSuccessOp", op_success)
      Easyop::Plugins::Instrumentation.attach_log_subscriber
      LogSubscriberSuccessOp.call
      expect(fl.infos).not_to be_empty
    end

    it "logs warn on failure" do
      fl = fake_logger
      rails_mod = Module.new do
        define_singleton_method(:logger) { fl }
        def self.respond_to?(m, *inc_priv); m == :logger || super; end
      end
      stub_const("Rails", rails_mod)
      stub_const("LogSubscriberFailureOp", op_failure)
      Easyop::Plugins::Instrumentation.attach_log_subscriber
      LogSubscriberFailureOp.call
      expect(fl.warns).not_to be_empty
    end
  end
end
