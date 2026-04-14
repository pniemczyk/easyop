# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/custom'

RSpec.describe Easyop::Events::Bus::Custom do
  def make_event(name = 'order.placed')
    Easyop::Events::Event.new(name: name)
  end

  describe '.new' do
    it 'accepts an adapter that responds to #publish and #subscribe' do
      adapter = Object.new
      def adapter.publish(event) = nil
      def adapter.subscribe(pattern, &block) = nil

      expect { described_class.new(adapter) }.not_to raise_error
    end

    it 'raises ArgumentError when adapter lacks #publish' do
      adapter = Object.new
      def adapter.subscribe(pattern, &block) = nil

      expect { described_class.new(adapter) }.to raise_error(ArgumentError, /publish/)
    end

    it 'raises ArgumentError when adapter lacks #subscribe' do
      adapter = Object.new
      def adapter.publish(event) = nil

      expect { described_class.new(adapter) }.to raise_error(ArgumentError, /subscribe/)
    end
  end

  describe '#publish' do
    it 'delegates to the adapter' do
      published = []
      adapter   = Object.new
      adapter.define_singleton_method(:publish)   { |e| published << e }
      adapter.define_singleton_method(:subscribe)  { |_p, &_b| }

      bus   = described_class.new(adapter)
      event = make_event
      bus.publish(event)

      expect(published).to eq([event])
    end
  end

  describe '#subscribe' do
    it 'delegates to the adapter' do
      subscribed = []
      adapter    = Object.new
      adapter.define_singleton_method(:publish)   { |_e| }
      adapter.define_singleton_method(:subscribe)  { |p, &b| subscribed << [p, b] }

      bus = described_class.new(adapter)
      blk = ->(e) { e }
      bus.subscribe('order.placed', &blk)

      expect(subscribed).to eq([['order.placed', blk]])
    end
  end

  describe '#unsubscribe' do
    it 'delegates to the adapter when it supports unsubscribe' do
      unsubscribed = []
      adapter      = Object.new
      adapter.define_singleton_method(:publish)     { |_e| }
      adapter.define_singleton_method(:subscribe)    { |_p, &_b| }
      adapter.define_singleton_method(:unsubscribe)  { |h| unsubscribed << h }

      bus = described_class.new(adapter)
      bus.unsubscribe(:handle)

      expect(unsubscribed).to eq([:handle])
    end

    it 'is a no-op when the adapter does not support unsubscribe' do
      adapter = Object.new
      adapter.define_singleton_method(:publish)   { |_e| }
      adapter.define_singleton_method(:subscribe)  { |_p, &_b| }

      bus = described_class.new(adapter)
      expect { bus.unsubscribe(:handle) }.not_to raise_error
    end
  end
end
