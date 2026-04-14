# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/memory'
require 'easyop/events/bus/custom'
require 'easyop/events/bus/active_support_notifications'
require 'easyop/events/registry'
require 'easyop/operation'

# Stub ActiveJob for async dispatch tests
module ActiveJob
  class Base
    @@enqueued = []
    def self.enqueued = @@enqueued
    def self.reset!   = @@enqueued.clear

    def self.set(**_opts) = self
    def self.perform_later(klass, attrs) = enqueued << { klass: klass, attrs: attrs }
  end
end

RSpec.describe Easyop::Events::Registry do
  before { described_class.reset! }

  def make_event(name = 'order.placed', payload = {})
    Easyop::Events::Event.new(name: name, payload: payload)
  end

  # ── bus= ─────────────────────────────────────────────────────────────────

  describe '.bus=' do
    it 'sets a Memory bus with :memory symbol' do
      described_class.bus = :memory
      expect(described_class.bus).to be_a(Easyop::Events::Bus::Memory)
    end

    it 'sets an AS::Notifications bus with :active_support symbol' do
      described_class.bus = :active_support
      expect(described_class.bus).to be_a(Easyop::Events::Bus::ActiveSupportNotifications)
    end

    it 'accepts a Bus::Base instance directly' do
      memory = Easyop::Events::Bus::Memory.new
      described_class.bus = memory
      expect(described_class.bus).to equal(memory)
    end

    it 'wraps a custom adapter that responds to #publish and #subscribe' do
      adapter = Object.new
      def adapter.publish(e) = nil
      def adapter.subscribe(p, &b) = nil

      described_class.bus = adapter
      expect(described_class.bus).to be_a(Easyop::Events::Bus::Custom)
    end

    it 'raises ArgumentError for an unknown value' do
      expect { described_class.bus = :unknown }.to raise_error(ArgumentError)
    end
  end

  # ── bus default ──────────────────────────────────────────────────────────

  describe '.bus (default)' do
    it 'returns a Memory bus by default' do
      expect(described_class.bus).to be_a(Easyop::Events::Bus::Memory)
    end
  end

  # ── reset! ───────────────────────────────────────────────────────────────

  describe '.reset!' do
    it 'replaces the bus with a fresh Memory instance' do
      described_class.bus = :active_support
      described_class.reset!
      expect(described_class.bus).to be_a(Easyop::Events::Bus::Memory)
    end

    it 'clears all registered subscriptions' do
      handler = Class.new { include Easyop::Operation; def call = nil }
      described_class.register_handler(pattern: 'order.placed', handler_class: handler)
      described_class.reset!
      expect(described_class.subscriptions).to be_empty
    end
  end

  # ── register_handler ─────────────────────────────────────────────────────

  describe '.register_handler' do
    it 'adds a subscription entry' do
      handler = Class.new { include Easyop::Operation; def call = nil }
      described_class.register_handler(pattern: 'order.placed', handler_class: handler)
      expect(described_class.subscriptions.size).to eq(1)
      expect(described_class.subscriptions.first[:handler_class]).to equal(handler)
    end

    it 'subscribes on the bus so publish delivers to the handler' do
      calls   = []
      handler = Class.new do
        include Easyop::Operation
        define_method(:call) { calls << ctx.event }
      end
      described_class.register_handler(pattern: 'order.placed', handler_class: handler)

      described_class.bus.publish(make_event('order.placed'))
      expect(calls.size).to eq(1)
      expect(calls.first).to be_a(Easyop::Events::Event)
    end

    it 'passes payload keys into ctx' do
      received_id = nil
      handler     = Class.new do
        include Easyop::Operation
        define_method(:call) { received_id = ctx.order_id }
      end
      described_class.register_handler(pattern: 'order.placed', handler_class: handler)

      described_class.bus.publish(make_event('order.placed', { order_id: 99 }))
      expect(received_id).to eq(99)
    end
  end

  # ── _dispatch (async) ────────────────────────────────────────────────────

  describe '._dispatch with async: true' do
    before { ActiveJob::Base.reset! }

    it 'calls call_async on the handler class when async: true and call_async is available' do
      enqueued = []
      handler  = Class.new { include Easyop::Operation; def call = nil }
      handler.define_singleton_method(:call_async) { |attrs, **_opts| enqueued << attrs }

      entry = { handler_class: handler, async: true, options: {} }
      described_class.send(:_dispatch, make_event('order.placed', { order_id: 7 }), entry)

      expect(enqueued.size).to eq(1)
      expect(enqueued.first[:order_id]).to eq(7)
      expect(enqueued.first[:event_data]).to be_a(Hash)
    end

    it 'falls back to synchronous call when call_async is unavailable' do
      calls   = []
      handler = Class.new do
        include Easyop::Operation
        define_method(:call) { calls << :sync }
      end

      entry = { handler_class: handler, async: true, options: {} }
      described_class.send(:_dispatch, make_event('order.placed'), entry)

      expect(calls).to eq([:sync])
    end

    it 'passes the queue option to call_async' do
      received_opts = {}
      handler = Class.new { include Easyop::Operation; def call = nil }
      handler.define_singleton_method(:call_async) { |_attrs, **opts| received_opts.merge!(opts) }

      entry = { handler_class: handler, async: true, options: { queue: 'low' } }
      described_class.send(:_dispatch, make_event('order.placed'), entry)

      expect(received_opts[:queue]).to eq('low')
    end
  end

  # ── handler failure isolation ────────────────────────────────────────────

  describe 'handler failure isolation' do
    it 'swallows exceptions raised by the handler' do
      handler = Class.new do
        include Easyop::Operation
        def call = raise 'boom'
      end
      described_class.register_handler(pattern: 'order.placed', handler_class: handler)

      expect { described_class.bus.publish(make_event('order.placed')) }.not_to raise_error
    end
  end
end
