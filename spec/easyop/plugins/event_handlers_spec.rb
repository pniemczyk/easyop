# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/memory'
require 'easyop/events/registry'
require 'easyop/operation'
require 'easyop/plugins/events'
require 'easyop/plugins/event_handlers'

RSpec.describe Easyop::Plugins::EventHandlers do
  before { Easyop::Events::Registry.reset! }

  def make_event(name = 'order.placed', payload = {})
    Easyop::Events::Event.new(name: name, payload: payload)
  end

  # ── install ──────────────────────────────────────────────────────────────

  describe '.install' do
    it 'extends ClassMethods on the base class' do
      op = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
      end
      expect(op).to respond_to(:on)
      expect(op).to respond_to(:_event_handler_registrations)
    end
  end

  # ── on DSL ───────────────────────────────────────────────────────────────

  describe '.on' do
    it 'registers the handler with the global Registry' do
      handler = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        def call = nil
      end

      subs = Easyop::Events::Registry.subscriptions
      expect(subs.size).to eq(1)
      expect(subs.first[:handler_class]).to equal(handler)
      expect(subs.first[:pattern]).to eq('order.placed')
    end

    it 'subscribes to the bus so published events reach the handler' do
      calls   = []
      handler = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        define_method(:call) { calls << ctx.event }
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed'))
      expect(calls.size).to eq(1)
      expect(calls.first).to be_a(Easyop::Events::Event)
    end
  end

  # ── ctx.event ────────────────────────────────────────────────────────────

  describe 'ctx.event' do
    it 'is the Easyop::Events::Event instance' do
      received = nil
      handler  = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        define_method(:call) { received = ctx.event }
      end

      event = make_event('order.placed')
      Easyop::Events::Registry.bus.publish(event)

      expect(received).to equal(event)
    end
  end

  # ── payload keys in ctx ──────────────────────────────────────────────────

  describe 'payload keys merged into ctx' do
    it 'exposes payload keys as ctx attributes' do
      order_id = nil
      handler  = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        define_method(:call) { order_id = ctx.order_id }
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed', { order_id: 42 }))
      expect(order_id).to eq(42)
    end
  end

  # ── glob patterns ────────────────────────────────────────────────────────

  describe 'glob patterns' do
    it 'matches order.* events' do
      received = []
      Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.*'
        define_method(:call) { received << ctx.event.name }
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed'))
      Easyop::Events::Registry.bus.publish(make_event('order.shipped'))
      Easyop::Events::Registry.bus.publish(make_event('user.created'))

      expect(received).to contain_exactly('order.placed', 'order.shipped')
    end

    it 'matches warehouse.** across nested segments' do
      received = []
      Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'warehouse.**'
        define_method(:call) { received << ctx.event.name }
      end

      Easyop::Events::Registry.bus.publish(make_event('warehouse.stock.updated'))
      Easyop::Events::Registry.bus.publish(make_event('warehouse.zone.moved'))
      Easyop::Events::Registry.bus.publish(make_event('order.placed'))

      expect(received).to contain_exactly('warehouse.stock.updated', 'warehouse.zone.moved')
    end
  end

  # ── multiple on declarations ─────────────────────────────────────────────

  describe 'multiple on declarations on one class' do
    it 'registers each pattern separately' do
      received = []
      Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        on 'order.shipped'
        define_method(:call) { received << ctx.event.name }
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed'))
      Easyop::Events::Registry.bus.publish(make_event('order.shipped'))

      expect(received).to contain_exactly('order.placed', 'order.shipped')
    end
  end

  # ── async dispatch ───────────────────────────────────────────────────────

  describe 'async: true' do
    it 'calls call_async on the handler when async and call_async is available' do
      enqueued = []
      handler  = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        define_singleton_method(:call_async) { |attrs, **_opts| enqueued << attrs }
        on 'order.placed', async: true
        def call = nil
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed', { order_id: 5 }))

      expect(enqueued.size).to eq(1)
      expect(enqueued.first[:order_id]).to eq(5)
      expect(enqueued.first[:event_data]).to be_a(Hash)
      expect(enqueued.first[:event_data][:name]).to eq('order.placed')
    end

    it 'includes queue option when specified' do
      received_opts = {}
      handler = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        define_singleton_method(:call_async) { |_attrs, **opts| received_opts.merge!(opts) }
        on 'order.placed', async: true, queue: 'low'
        def call = nil
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed'))
      expect(received_opts[:queue]).to eq('low')
    end

    it 'falls back to sync call when call_async is not available' do
      calls   = []
      handler = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed', async: true
        define_method(:call) { calls << :sync }
      end

      Easyop::Events::Registry.bus.publish(make_event('order.placed'))
      expect(calls).to eq([:sync])
    end
  end

  # ── end-to-end with Events plugin ────────────────────────────────────────

  describe 'end-to-end with Easyop::Plugins::Events' do
    it 'handler is invoked when a producer operation fires' do
      received = []

      handler = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        define_method(:call) { received << ctx.order_id }
      end

      producer = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Events
        emits 'order.placed', payload: [:order_id]
        define_method(:call) { ctx.order_id = 99 }
      end

      producer.call(order_id: nil)
      expect(received).to eq([99])
    end
  end

  # ── handler failure isolation ────────────────────────────────────────────

  describe 'handler failure isolation' do
    it 'does not propagate handler exceptions to the publisher' do
      Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::EventHandlers
        on 'order.placed'
        def call = raise 'handler boom'
      end

      expect {
        Easyop::Events::Registry.bus.publish(make_event('order.placed'))
      }.not_to raise_error
    end
  end
end
