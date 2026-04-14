# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/spec/'
  minimum_coverage 80
  command_name 'Minitest'
end

require 'minitest/autorun'
require 'easyop'

# ── Shared test stubs ──────────────────────────────────────────────────────────

# Stub ActiveSupport::Notifications with yield-before-notify semantics so the
# Instrumentation plugin can populate payload inside the block before subscribers see it.
unless defined?(::ActiveSupport::Notifications)
  module ActiveSupport
    module Notifications
      @subs   = Hash.new { |h, k| h[k] = [] }
      @events = []

      class << self
        def instrument(name, payload = {})
          # Yield block FIRST so callers can populate payload before subscribers fire.
          yield payload if block_given?
          @events << { name: name, payload: payload }
          @subs.each do |pattern, blocks|
            matches = case pattern
                      when Regexp then pattern.match?(name)
                      when String then pattern == name
                      end
            blocks.each { |blk| blk.call(name, nil, nil, nil, payload) } if matches
          end
          payload
        end

        def subscribe(pattern, &block)
          handle = [pattern, block]
          (@subs[pattern] ||= []) << block
          handle
        end

        def unsubscribe(handle)
          return unless handle.is_a?(Array)
          pattern, blk = handle
          @subs[pattern]&.delete(blk)
        end

        def reset!
          @subs   = {}
          @events = []
        end

        def events
          @events
        end
      end

      class Event
        attr_reader :name, :payload, :duration

        def initialize(*args)
          @name     = args[0].to_s
          @payload  = args[4] || {}
          @duration = 1.0
        end
      end
    end
  end
end

# Stub ActiveRecord::Base so recording tests have column_names + create!, and
# transactional tests have .transaction, without a real database.
unless defined?(::ActiveRecord::Base)
  module ActiveRecord
    class Base
      @@columns = %w[operation_name success error_message params_data duration_ms performed_at].freeze
      @@records = []
      @@tx_count = 0

      class << self
        def column_names;    @@columns;   end
        def records;         @@records;   end
        def tx_count;        @@tx_count;  end
        def create!(attrs);  @@records << attrs; end
        def transaction;     @@tx_count += 1; yield; end
        def reset_test_state!
          @@records  = []
          @@tx_count = 0
        end
      end
    end
  end
end

# Stub String#constantize if absent (normally added by ActiveSupport).
unless String.method_defined?(:constantize)
  class String
    def constantize
      Object.const_get(self)
    end
  end
end

# Stub Time.current if absent (normally added by ActiveSupport / Rails).
unless Time.respond_to?(:current)
  class Time
    def self.current = now
  end
end

# Optional components used across tests — require them all here so individual
# test files don't need to worry about load order.
require 'easyop/plugins/base'
require 'easyop/plugins/instrumentation'
require 'easyop/plugins/recording'
require 'easyop/plugins/async'
require 'easyop/plugins/transactional'
require 'easyop/events/event'
require 'easyop/events/bus'
require 'easyop/events/bus/adapter'
require 'easyop/events/bus/memory'
require 'easyop/events/bus/custom'
require 'easyop/events/bus/active_support_notifications'
require 'easyop/events/registry'
require 'easyop/plugins/events'
require 'easyop/plugins/event_handlers'

# Shared helpers included in every test class via `include EasyopTestHelper`.
module EasyopTestHelper
  def setup
    Easyop.reset_config!
  end

  # Register a named constant for the duration of a test, then clean up.
  # Usage: set_const('MyOp', klass)
  def set_const(name, value)
    (@_test_consts ||= []) << name
    Object.const_set(name, value)
    value
  end

  def teardown
    (@_test_consts || []).each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    super
  end
end
