# frozen_string_literal: true

require "spec_helper"
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/adapter"

RSpec.describe Easyop::Events::Bus::Adapter do
  # Minimal concrete subclass used throughout the suite.
  let(:concrete_class) do
    Class.new(described_class) do
      def initialize
        super
        @subs  = []
        @mutex = Mutex.new
      end

      def publish(event)
        snap = @mutex.synchronize { @subs.dup }
        snap.each do |sub|
          _safe_invoke(sub[:handler], event) if _pattern_matches?(sub[:pattern], event.name)
        end
      end

      def subscribe(pattern, &block)
        handle = { pattern: _compile_pattern(pattern), handler: block }
        @mutex.synchronize { @subs << handle }
        handle
      end

      def unsubscribe(handle)
        @mutex.synchronize { @subs.delete(handle) }
      end
    end
  end

  subject(:bus) { concrete_class.new }

  let(:event) { Easyop::Events::Event.new(name: "order.placed", payload: { order_id: 42 }) }

  # ── ancestry ──────────────────────────────────────────────────────────────

  it "is a subclass of Bus::Base" do
    expect(bus).to be_a(Easyop::Events::Bus::Base)
  end

  # ── _safe_invoke ──────────────────────────────────────────────────────────

  describe "#_safe_invoke (via publish)" do
    it "delivers the event to a matching handler" do
      received = []
      bus.subscribe("order.placed") { |e| received << e }
      bus.publish(event)
      expect(received).to eq([event])
    end

    it "swallows StandardError raised by a handler without affecting others" do
      second = []
      bus.subscribe("order.*") { raise "boom" }
      bus.subscribe("order.*") { |e| second << e }
      expect { bus.publish(event) }.not_to raise_error
      expect(second).to eq([event])
    end

    it "swallows RuntimeError (StandardError subclass)" do
      bus.subscribe("order.*") { raise RuntimeError, "uh oh" }
      expect { bus.publish(event) }.not_to raise_error
    end
  end

  # ── _compile_pattern ─────────────────────────────────────────────────────

  describe "#_compile_pattern" do
    subject(:compile) { ->(p) { bus.send(:_compile_pattern, p) } }

    it "passes Regexp through unchanged" do
      r = /order\.\w+/
      expect(compile.call(r)).to be(r)
    end

    it "compiles an exact string to an anchored Regexp that matches fully" do
      r = compile.call("order.placed")
      expect(r).to match("order.placed")
      expect(r).not_to match("order.placed.v2")
      expect(r).not_to match("xorder.placed")
    end

    it "compiles a single-segment glob (* = one dot-free segment)" do
      r = compile.call("order.*")
      expect(r).to match("order.placed")
      expect(r).to match("order.failed")
      expect(r).not_to match("order.placed.v2")
      expect(r).not_to match("order")
    end

    it "compiles a multi-segment glob (** = any sequence including dots)" do
      r = compile.call("warehouse.**")
      expect(r).to match("warehouse.stock.low")
      expect(r).to match("warehouse.alert.fire.east")
      expect(r).not_to match("warehouse")
      expect(r).not_to match("other.warehouse.stock")
    end

    it "memoizes identical patterns — same object returned on second call" do
      r1 = compile.call("order.*")
      r2 = compile.call("order.*")
      expect(r1).to be(r2)
    end

    it "does not conflate different patterns in the cache" do
      r1 = compile.call("order.*")
      r2 = compile.call("order.**")
      expect(r1).not_to eq(r2)
    end
  end

  # ── subscribe / unsubscribe ───────────────────────────────────────────────

  describe "subscription lifecycle" do
    it "delivers to a glob subscriber" do
      received = []
      bus.subscribe("order.*") { |e| received << e.name }
      bus.publish(event)
      expect(received).to eq(["order.placed"])
    end

    it "does not deliver to a non-matching subscriber" do
      received = []
      bus.subscribe("invoice.*") { |e| received << e }
      bus.publish(event)
      expect(received).to be_empty
    end

    it "stops delivering after unsubscribe" do
      received = []
      handle = bus.subscribe("order.*") { |e| received << e }
      bus.publish(event)
      bus.unsubscribe(handle)
      bus.publish(event)
      expect(received.size).to eq(1)
    end
  end
end
