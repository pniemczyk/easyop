# frozen_string_literal: true

require 'test_helper'

class EventTest < Minitest::Test
  include EasyopTestHelper

  def build(**kwargs)
    Easyop::Events::Event.new(**{ name: 'order.placed' }.merge(kwargs))
  end

  # ── Construction ─────────────────────────────────────────────────────────────

  def test_dot_new_sets_name_as_string
    event = build(name: :order_placed)
    assert_equal 'order_placed', event.name
  end

  def test_dot_new_freezes_name
    event = build
    assert_predicate event.name, :frozen?
  end

  def test_dot_new_freezes_payload
    event = build(payload: { x: 1 })
    assert_predicate event.payload, :frozen?
  end

  def test_dot_new_freezes_metadata
    event = build(metadata: { corr: 'id' })
    assert_predicate event.metadata, :frozen?
  end

  def test_dot_new_freezes_event_itself
    event = build
    assert_predicate event, :frozen?
  end

  def test_dot_new_defaults_payload_to_empty_hash
    event = build
    assert_equal({}, event.payload)
  end

  def test_dot_new_defaults_metadata_to_empty_hash
    event = build
    assert_equal({}, event.metadata)
  end

  def test_dot_new_defaults_timestamp_to_now
    before = Time.now
    event  = build
    after  = Time.now
    assert event.timestamp >= before
    assert event.timestamp <= after
  end

  def test_dot_new_accepts_explicit_timestamp
    t = Time.now - 3600
    event = build(timestamp: t)
    assert_equal t, event.timestamp
  end

  def test_dot_new_defaults_source_to_nil
    event = build
    assert_nil event.source
  end

  def test_dot_new_sets_source_and_freezes_it
    event = build(source: 'PlaceOrder')
    assert_equal 'PlaceOrder', event.source
    assert_predicate event.source, :frozen?
  end

  # ── to_h ────────────────────────────────────────────────────────────────────

  def test_hash_to_h_returns_all_fields
    t = Time.now
    event = Easyop::Events::Event.new(
      name:      'order.placed',
      payload:   { id: 1 },
      metadata:  { env: 'test' },
      timestamp: t,
      source:    'PlaceOrder'
    )
    h = event.to_h
    assert_equal 'order.placed', h[:name]
    assert_equal({ id: 1 },      h[:payload])
    assert_equal({ env: 'test' }, h[:metadata])
    assert_equal t,               h[:timestamp]
    assert_equal 'PlaceOrder',    h[:source]
  end

  # ── inspect ──────────────────────────────────────────────────────────────────

  def test_hash_inspect_includes_name_and_source
    event = build(source: 'MyOp')
    assert_includes event.inspect, 'order.placed'
    assert_includes event.inspect, 'MyOp'
  end
end
