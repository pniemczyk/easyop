# frozen_string_literal: true

require 'spec_helper'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/memory'
require 'easyop/events/registry'
require 'easyop/operation'
require 'easyop/plugins/events'

RSpec.describe Easyop::Plugins::Events do
  # Shared bus for capturing published events in tests
  let(:bus) { Easyop::Events::Bus::Memory.new }

  def make_op(&blk)
    b = bus
    Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Events, bus: b
      class_eval(&blk) if blk
    end
  end

  # ── install ──────────────────────────────────────────────────────────────

  describe '.install' do
    it 'extends ClassMethods on the base class' do
      op = make_op
      expect(op).to respond_to(:emits)
      expect(op).to respond_to(:_emitted_events)
    end

    it 'prepends RunWrapper' do
      op = make_op
      expect(op.ancestors).to include(described_class::RunWrapper)
    end
  end

  # ── emits on: :success ───────────────────────────────────────────────────

  describe 'emits on: :success (default)' do
    it 'fires the event when the operation succeeds' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed' }
      op.call

      expect(published.size).to eq(1)
      expect(published.first.name).to eq('order.placed')
    end

    it 'does not fire when the operation fails' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op do
        emits 'order.placed'
        def call = ctx.fail!(error: 'nope')
      end
      op.call

      expect(published).to be_empty
    end
  end

  # ── emits on: :failure ───────────────────────────────────────────────────

  describe 'emits on: :failure' do
    it 'fires the event when the operation fails' do
      published = []
      bus.subscribe('order.failed') { |e| published << e }

      op = make_op do
        emits 'order.failed', on: :failure
        def call = ctx.fail!(error: 'oops')
      end
      op.call

      expect(published.size).to eq(1)
    end

    it 'does not fire when the operation succeeds' do
      published = []
      bus.subscribe('order.failed') { |e| published << e }

      op = make_op { emits 'order.failed', on: :failure }
      op.call

      expect(published).to be_empty
    end
  end

  # ── emits on: :always ────────────────────────────────────────────────────

  describe 'emits on: :always' do
    it 'fires on success' do
      published = []
      bus.subscribe('order.attempted') { |e| published << e }

      op = make_op { emits 'order.attempted', on: :always }
      op.call

      expect(published.size).to eq(1)
    end

    it 'fires on failure' do
      published = []
      bus.subscribe('order.attempted') { |e| published << e }

      op = make_op do
        emits 'order.attempted', on: :always
        def call = ctx.fail!
      end
      op.call

      expect(published.size).to eq(1)
    end
  end

  # ── payload extraction ───────────────────────────────────────────────────

  describe 'payload: Proc' do
    it 'calls the proc with ctx and uses the result as payload' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed', payload: ->(ctx) { { total: ctx.total } } }
      op.call(total: 5000)

      expect(published.first.payload).to eq({ total: 5000 })
    end
  end

  describe 'payload: Array' do
    it 'slices the specified keys from ctx' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed', payload: [:order_id] }
      op.call(order_id: 42, noise: 'ignore')

      expect(published.first.payload).to eq({ order_id: 42 })
    end
  end

  describe 'payload: nil (default)' do
    it 'uses the full ctx hash as payload' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed' }
      op.call(order_id: 7)

      expect(published.first.payload[:order_id]).to eq(7)
    end
  end

  # ── guard ────────────────────────────────────────────────────────────────

  describe 'guard: Proc' do
    it 'fires when the guard returns true' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed', guard: ->(ctx) { ctx.premium? } }
      op.call(premium: true)

      expect(published.size).to eq(1)
    end

    it 'does not fire when the guard returns false' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed', guard: ->(ctx) { ctx.premium? } }
      op.call(premium: false)

      expect(published).to be_empty
    end
  end

  # ── timing ───────────────────────────────────────────────────────────────

  describe 'event timing' do
    it 'fires events AFTER the operation call method completes' do
      order = []
      bus.subscribe('order.placed') { |_e| order << :event }

      op = make_op do
        emits 'order.placed'
        define_method(:call) { order << :call }
      end
      op.call

      expect(order).to eq([:call, :event])
    end

    it 'fires events even when raise_on_failure: true raises Ctx::Failure' do
      published = []
      bus.subscribe('order.failed') { |e| published << e }

      op = make_op do
        emits 'order.failed', on: :failure
        def call = ctx.fail!
      end

      expect { op.call! }.to raise_error(Easyop::Ctx::Failure)
      expect(published.size).to eq(1)
    end
  end

  # ── source ───────────────────────────────────────────────────────────────

  describe 'event source' do
    it 'sets the source to the operation class name' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      op = make_op { emits 'order.placed' }
      stub_const('NamedOp', op)
      NamedOp.call

      expect(published.first.source).to eq('NamedOp')
    end
  end

  # ── metadata ─────────────────────────────────────────────────────────────

  describe 'metadata: Hash' do
    it 'merges the hash into every event' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      b = bus
      op = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Events, bus: b, metadata: { env: 'test' }
        emits 'order.placed'
      end
      op.call

      expect(published.first.metadata).to eq({ env: 'test' })
    end
  end

  describe 'metadata: Proc' do
    it 'calls the proc with ctx and uses the result' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      b = bus
      op = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Events, bus: b, metadata: ->(ctx) { { user_id: ctx.user_id } }
        emits 'order.placed'
      end
      op.call(user_id: 5)

      expect(published.first.metadata).to eq({ user_id: 5 })
    end
  end

  # ── inheritance ───────────────────────────────────────────────────────────

  describe 'inheritance' do
    it 'subclass inherits parent emits declarations' do
      published = []
      bus.subscribe('order.placed') { |e| published << e }

      parent = make_op { emits 'order.placed' }
      child  = Class.new(parent)
      child.call

      expect(published.size).to eq(1)
    end

    it 'subclass additions do not pollute the parent' do
      parent_published = []
      child_published  = []

      bus.subscribe('base.event')  { |e| parent_published << e }
      bus.subscribe('child.event') { |e| child_published << e }

      parent = make_op { emits 'base.event' }
      child  = Class.new(parent) { emits 'child.event' }

      parent.call
      expect(parent_published.size).to eq(1)
      expect(child_published).to be_empty

      parent_published.clear

      child.call
      expect(parent_published.size).to eq(1)
      expect(child_published.size).to eq(1)
    end
  end

  # ── publish failure isolation ────────────────────────────────────────────

  describe 'publish failure isolation' do
    it 'does not crash the operation when publish raises' do
      broken_bus = Easyop::Events::Bus::Memory.new
      broken_bus.subscribe('order.placed') { raise 'bus exploded' }

      b  = broken_bus
      op = Class.new do
        include Easyop::Operation
        plugin Easyop::Plugins::Events, bus: b
        emits 'order.placed'
      end

      expect { op.call }.not_to raise_error
    end
  end
end
