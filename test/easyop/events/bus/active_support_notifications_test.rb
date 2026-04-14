# frozen_string_literal: true

require 'test_helper'

# ActiveSupport::Notifications is stubbed in test_helper.rb.

class BusActiveSupNotificationsTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    ActiveSupport::Notifications.reset! if ActiveSupport::Notifications.respond_to?(:reset!)
  end

  def teardown
    ActiveSupport::Notifications.reset! if ActiveSupport::Notifications.respond_to?(:reset!)
    super
  end

  def bus
    @bus ||= Easyop::Events::Bus::ActiveSupportNotifications.new
  end

  def event(name = 'order.placed', payload = {})
    Easyop::Events::Event.new(name: name, payload: payload)
  end

  # ── publish ───────────────────────────────────────────────────────────────────

  def test_publish_instruments_event_name
    instrumented = []
    ActiveSupport::Notifications.subscribe('order.placed') do |name, *|
      instrumented << name
    end
    bus.publish(event('order.placed'))
    assert_includes instrumented, 'order.placed'
  end

  # ── subscribe reconstructs Easyop::Events::Event ────────────────────────────

  def test_subscribe_yields_easyop_event_on_matching_publish
    received = []
    bus.subscribe('order.placed') { |e| received << e }
    bus.publish(event('order.placed', order_id: 1))
    assert_equal 1, received.size
    assert_instance_of Easyop::Events::Event, received.first
    assert_equal 'order.placed', received.first.name
  end

  # ── glob patterns converted to Regexp for AS ─────────────────────────────────

  def test_subscribe_with_glob_matches_events
    received = []
    bus.subscribe('order.*') { |e| received << e.name }
    bus.publish(event('order.placed'))
    bus.publish(event('order.shipped'))
    assert_equal 2, received.size
  end

  # ── Raises LoadError when AS not defined ─────────────────────────────────────

  def test_publish_raises_load_error_without_active_support
    # Hide AS temporarily
    as_backup = ::ActiveSupport::Notifications
    ::ActiveSupport.send(:remove_const, :Notifications)

    b = Easyop::Events::Bus::ActiveSupportNotifications.new
    assert_raises(LoadError) { b.publish(event) }
  ensure
    ::ActiveSupport.const_set(:Notifications, as_backup) if defined?(as_backup)
  end

  def test_subscribe_raises_load_error_without_active_support
    as_backup = ::ActiveSupport::Notifications
    ::ActiveSupport.send(:remove_const, :Notifications)

    b = Easyop::Events::Bus::ActiveSupportNotifications.new
    assert_raises(LoadError) { b.subscribe('x') { } }
  ensure
    ::ActiveSupport.const_set(:Notifications, as_backup) if defined?(as_backup)
  end
end
