# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/active_support_notifications'

# ── Minimal ActiveSupport::Notifications stub ─────────────────────────────────
# Uses the same 5-arg convention as instrumentation_spec.rb so the two stubs
# are compatible when the full suite runs (same constant, same API).
unless defined?(ActiveSupport)
  module ActiveSupport
    module Notifications
      class Event
        attr_reader :name, :payload

        def initialize(name, started, finished, _id, payload)
          @name    = name
          @started = started
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
          block  # return as handle
        end

        def instrument(name, payload = {})
          started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result   = block_given? ? yield(payload) : nil
          finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          _subscribers[name].each { |s| s.call(name, started, finished, 'id', payload) }
          result
        end

        def unsubscribe(handle)
          _subscribers.each_value { |subs| subs.delete(handle) }
        end

        def reset!
          @_subscribers = nil
        end
      end
    end
  end
end
# ──────────────────────────────────────────────────────────────────────────────

RSpec.describe Easyop::Events::Bus::ActiveSupportNotifications do
  subject(:bus) { described_class.new }

  before { ::ActiveSupport::Notifications.reset! if ::ActiveSupport::Notifications.respond_to?(:reset!) }

  def make_event(name, payload = {})
    Easyop::Events::Event.new(name: name, payload: payload, source: 'TestOp')
  end

  describe '#publish' do
    it 'instruments the event via ActiveSupport::Notifications with the correct name' do
      instrumented = []
      ::ActiveSupport::Notifications.subscribe('order.placed') do |name, *_rest|
        instrumented << name
      end

      bus.publish(make_event('order.placed'))
      expect(instrumented).to eq(['order.placed'])
    end

    it 'includes the event hash in the AS notification payload' do
      received_payload = nil
      ::ActiveSupport::Notifications.subscribe('order.placed') do |_name, _s, _f, _id, payload|
        received_payload = payload
      end

      bus.publish(make_event('order.placed', { order_id: 42 }))
      expect(received_payload[:source]).to eq('TestOp')
      expect(received_payload[:payload]).to eq({ order_id: 42 })
    end
  end

  describe '#subscribe' do
    it 'receives events published via the bus and reconstructs an Easyop::Events::Event' do
      received = []
      bus.subscribe('order.placed') { |e| received << e }

      bus.publish(make_event('order.placed', { order_id: 99 }))

      expect(received.size).to eq(1)
      expect(received.first).to be_a(Easyop::Events::Event)
      expect(received.first.name).to eq('order.placed')
    end

    it 'passes payload through to the reconstructed event' do
      received = nil
      bus.subscribe('order.placed') { |e| received = e }

      bus.publish(make_event('order.placed', { order_id: 7 }))
      expect(received.payload).to eq({ order_id: 7 })
    end
  end

  describe 'without ActiveSupport::Notifications' do
    it 'raises LoadError on publish when AS is not defined' do
      hide_const('ActiveSupport')
      expect { bus.publish(make_event('x')) }.to raise_error(LoadError, /activesupport/i)
    end

    it 'raises LoadError on subscribe when AS is not defined' do
      hide_const('ActiveSupport')
      expect { bus.subscribe('x') { } }.to raise_error(LoadError, /activesupport/i)
    end
  end
end
