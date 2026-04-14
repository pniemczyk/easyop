# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/memory'

RSpec.describe Easyop::Events::Bus::Memory do
  subject(:bus) { described_class.new }

  def make_event(name, payload = {})
    Easyop::Events::Event.new(name: name, payload: payload)
  end

  # ── subscribe / publish ──────────────────────────────────────────────────────

  describe '#subscribe and #publish' do
    it 'delivers an event to a matching subscriber' do
      received = []
      bus.subscribe('order.placed') { |e| received << e }

      event = make_event('order.placed')
      bus.publish(event)

      expect(received).to eq([event])
    end

    it 'does not deliver to a non-matching subscriber' do
      received = []
      bus.subscribe('order.placed') { |e| received << e }
      bus.publish(make_event('order.failed'))

      expect(received).to be_empty
    end

    it 'delivers to multiple subscribers for the same pattern' do
      calls = 0
      bus.subscribe('order.placed') { calls += 1 }
      bus.subscribe('order.placed') { calls += 1 }
      bus.publish(make_event('order.placed'))

      expect(calls).to eq(2)
    end
  end

  # ── glob patterns ─────────────────────────────────────────────────────────

  describe 'single-segment glob (*)' do
    it 'matches any single segment' do
      received = []
      bus.subscribe('order.*') { |e| received << e.name }

      bus.publish(make_event('order.placed'))
      bus.publish(make_event('order.shipped'))

      expect(received).to contain_exactly('order.placed', 'order.shipped')
    end

    it 'does not match across segments' do
      received = []
      bus.subscribe('order.*') { |e| received << e.name }
      bus.publish(make_event('order.payment.failed'))

      expect(received).to be_empty
    end
  end

  describe 'multi-segment glob (**)' do
    it 'matches across segment boundaries' do
      received = []
      bus.subscribe('warehouse.**') { |e| received << e.name }

      bus.publish(make_event('warehouse.stock.updated'))
      bus.publish(make_event('warehouse.zone.moved'))

      expect(received).to contain_exactly('warehouse.stock.updated', 'warehouse.zone.moved')
    end

    it 'does not match unrelated prefixes' do
      received = []
      bus.subscribe('warehouse.**') { |e| received << e.name }
      bus.publish(make_event('order.placed'))

      expect(received).to be_empty
    end
  end

  describe 'Regexp pattern' do
    it 'matches events via the regexp' do
      received = []
      bus.subscribe(/\Aorder\./) { |e| received << e.name }

      bus.publish(make_event('order.placed'))
      bus.publish(make_event('order.shipped'))
      bus.publish(make_event('user.created'))

      expect(received).to contain_exactly('order.placed', 'order.shipped')
    end
  end

  # ── unsubscribe ───────────────────────────────────────────────────────────

  describe '#unsubscribe' do
    it 'removes the subscription' do
      received = []
      handle   = bus.subscribe('order.placed') { |e| received << e }
      bus.unsubscribe(handle)
      bus.publish(make_event('order.placed'))

      expect(received).to be_empty
    end
  end

  # ── clear! ────────────────────────────────────────────────────────────────

  describe '#clear!' do
    it 'removes all subscriptions' do
      received = []
      bus.subscribe('order.placed') { |e| received << e }
      bus.subscribe('order.failed') { |e| received << e }
      bus.clear!

      bus.publish(make_event('order.placed'))
      bus.publish(make_event('order.failed'))

      expect(received).to be_empty
      expect(bus.subscriber_count).to eq(0)
    end
  end

  # ── handler isolation ────────────────────────────────────────────────────

  describe 'handler failure isolation' do
    it 'does not stop other handlers when one raises' do
      calls = []
      bus.subscribe('order.placed') { raise 'boom' }
      bus.subscribe('order.placed') { |e| calls << e.name }

      expect { bus.publish(make_event('order.placed')) }.not_to raise_error
      expect(calls).to eq(['order.placed'])
    end
  end

  # ── thread safety ─────────────────────────────────────────────────────────

  describe 'thread safety' do
    it 'handles concurrent subscriptions and publishes without data corruption' do
      received = []
      mutex    = Mutex.new

      threads = 10.times.map do |i|
        Thread.new do
          bus.subscribe("event.#{i}") { |e| mutex.synchronize { received << e.name } }
          bus.publish(make_event("event.#{i}"))
        end
      end
      threads.each(&:join)

      expect(received.size).to eq(10)
    end
  end
end
