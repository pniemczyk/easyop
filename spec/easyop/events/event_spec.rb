# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'

RSpec.describe Easyop::Events::Event do
  describe '#initialize' do
    it 'sets name as a frozen string' do
      event = described_class.new(name: :order_placed)
      expect(event.name).to eq('order_placed')
      expect(event.name).to be_frozen
    end

    it 'sets payload and freezes it' do
      event = described_class.new(name: 'order.placed', payload: { id: 1 })
      expect(event.payload).to eq({ id: 1 })
      expect(event.payload).to be_frozen
    end

    it 'defaults payload to a frozen empty hash' do
      event = described_class.new(name: 'order.placed')
      expect(event.payload).to eq({})
      expect(event.payload).to be_frozen
    end

    it 'sets metadata and freezes it' do
      event = described_class.new(name: 'order.placed', metadata: { correlation_id: 'abc' })
      expect(event.metadata).to eq({ correlation_id: 'abc' })
      expect(event.metadata).to be_frozen
    end

    it 'defaults metadata to a frozen empty hash' do
      event = described_class.new(name: 'order.placed')
      expect(event.metadata).to eq({})
      expect(event.metadata).to be_frozen
    end

    it 'defaults timestamp to Time.now' do
      before = Time.now
      event  = described_class.new(name: 'order.placed')
      after  = Time.now
      expect(event.timestamp).to be >= before
      expect(event.timestamp).to be <= after
    end

    it 'accepts an explicit timestamp' do
      t     = Time.now - 3600
      event = described_class.new(name: 'order.placed', timestamp: t)
      expect(event.timestamp).to eq(t)
    end

    it 'sets source' do
      event = described_class.new(name: 'order.placed', source: 'PlaceOrder')
      expect(event.source).to eq('PlaceOrder')
      expect(event.source).to be_frozen
    end

    it 'defaults source to nil' do
      event = described_class.new(name: 'order.placed')
      expect(event.source).to be_nil
    end

    it 'freezes the event itself' do
      event = described_class.new(name: 'order.placed')
      expect(event).to be_frozen
    end
  end

  describe '#to_h' do
    it 'returns a hash with all fields' do
      t     = Time.now
      event = described_class.new(name: 'order.placed', payload: { id: 1 },
                                  metadata: { x: 'y' }, timestamp: t, source: 'Foo')
      expect(event.to_h).to eq(
        name:      'order.placed',
        payload:   { id: 1 },
        metadata:  { x: 'y' },
        timestamp: t,
        source:    'Foo'
      )
    end
  end

  describe '#inspect' do
    it 'includes name and source' do
      event = described_class.new(name: 'order.placed', source: 'PlaceOrder')
      expect(event.inspect).to include('order.placed')
      expect(event.inspect).to include('PlaceOrder')
    end
  end
end
