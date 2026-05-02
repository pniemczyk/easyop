# frozen_string_literal: true

require 'test_helper'
require 'easyop/scheduler'

class SchedulerSerializerTest < Minitest::Test
  include EasyopTestHelper

  # ── Primitives ──────────────────────────────────────────────────────────────

  def test_serialize_deserialize_string
    result = roundtrip(name: 'hello')
    assert_equal 'hello', result[:name]
  end

  def test_serialize_deserialize_integer
    result = roundtrip(count: 42)
    assert_equal 42, result[:count]
  end

  def test_serialize_deserialize_float
    result = roundtrip(amount: 3.14)
    assert_in_delta 3.14, result[:amount], 0.001
  end

  def test_serialize_deserialize_nil
    result = roundtrip(val: nil)
    assert_nil result[:val]
  end

  def test_serialize_deserialize_boolean_true
    result = roundtrip(flag: true)
    assert_equal true, result[:flag]
  end

  def test_serialize_deserialize_boolean_false
    result = roundtrip(flag: false)
    assert_equal false, result[:flag]
  end

  def test_serialize_deserialize_array
    result = roundtrip(ids: [1, 2, 3])
    assert_equal [1, 2, 3], result[:ids]
  end

  def test_serialize_deserialize_nested_hash
    result = roundtrip(config: { key: 'val', nested: { x: 1 } })
    assert_equal 'val', result[:config][:key]
    assert_equal 1, result[:config][:nested][:x]
  end

  def test_serialize_converts_symbol_keys_to_strings
    json = Easyop::Scheduler::Serializer.serialize(foo: 'bar')
    parsed = JSON.parse(json)
    assert parsed.key?('foo'), 'expected string key "foo"'
    refute parsed.key?(:foo), 'did not expect symbol key'
  end

  def test_deserialize_converts_string_keys_to_symbols
    json = JSON.dump('name' => 'Alice')
    result = Easyop::Scheduler::Serializer.deserialize(json)
    assert result.key?(:name), 'expected symbol key :name'
    assert_equal 'Alice', result[:name]
  end

  def test_serialize_ar_object_to_pointer
    ar_obj = StubUser.new
    json   = Easyop::Scheduler::Serializer.serialize(user: ar_obj)
    parsed = JSON.parse(json)

    assert_equal StubUser.name, parsed['user']['__ar_class']
    assert_equal 5,             parsed['user']['__ar_id']
  end

  def test_deserialize_reloads_ar_object
    json   = JSON.dump('user' => { '__ar_class' => StubUser.name, '__ar_id' => 5 })
    result = Easyop::Scheduler::Serializer.deserialize(json)
    assert_equal 'stub_user_5', result[:user]
  end

  private

  # Inherits from the test stub's ActiveRecord::Base so is_a?(ActiveRecord::Base) is true.
  class StubUser < ActiveRecord::Base
    def id = 5
    def self.find(id) = "stub_user_#{id}"
  end

  def roundtrip(attrs)
    json = Easyop::Scheduler::Serializer.serialize(attrs)
    Easyop::Scheduler::Serializer.deserialize(json)
  end
end

class SchedulerConfigurationTest < Minitest::Test
  include EasyopTestHelper

  def test_default_scheduler_model
    assert_equal 'EasyScheduledTask', Easyop.config.scheduler_model
  end

  def test_default_batch_size
    assert_equal 50, Easyop.config.scheduler_batch_size
  end

  def test_default_lock_window
    assert_equal 300, Easyop.config.scheduler_lock_window
  end

  def test_default_stuck_threshold
    assert_equal 600, Easyop.config.scheduler_stuck_threshold
  end

  def test_default_max_attempts
    assert_equal 3, Easyop.config.scheduler_default_max_attempts
  end

  def test_default_backoff
    assert_equal :exponential, Easyop.config.scheduler_default_backoff
  end

  def test_default_dead_letter_callback
    assert_nil Easyop.config.scheduler_dead_letter_callback
  end

  def test_configure_scheduler_model
    Easyop.configure { |c| c.scheduler_model = 'CustomTask' }
    assert_equal 'CustomTask', Easyop.config.scheduler_model
  end

  def test_configure_batch_size
    Easyop.configure { |c| c.scheduler_batch_size = 25 }
    assert_equal 25, Easyop.config.scheduler_batch_size
  end

  def test_configure_dead_letter_callback
    called_with = nil
    Easyop.configure { |c| c.scheduler_dead_letter_callback = ->(t) { called_with = t } }
    Easyop.config.scheduler_dead_letter_callback.call('task')
    assert_equal 'task', called_with
  end
end

class SchedulerBackoffTest < Minitest::Test
  include EasyopTestHelper

  def test_linear_backoff
    Easyop.configure { |c| c.scheduler_default_backoff = :linear }
    task = MockTask.new(attempts: 4)
    result = Easyop::Scheduler.send(:_compute_backoff, task)
    # 4 * 30 = 120 seconds from now
    assert_in_delta Time.current.to_i + 120, result.to_i, 5
  end

  def test_exponential_backoff
    Easyop.configure { |c| c.scheduler_default_backoff = :exponential }
    task = MockTask.new(attempts: 2)
    result = Easyop::Scheduler.send(:_compute_backoff, task)
    # 2^2 * 60 = 240 seconds from now
    assert_in_delta Time.current.to_i + 240, result.to_i, 5
  end

  def test_exponential_backoff_caps_at_one_hour
    Easyop.configure { |c| c.scheduler_default_backoff = :exponential }
    task = MockTask.new(attempts: 20)
    result = Easyop::Scheduler.send(:_compute_backoff, task)
    assert_in_delta Time.current.to_i + 3600, result.to_i, 5
  end

  def test_proc_backoff
    Easyop.configure { |c| c.scheduler_default_backoff = ->(attempts, _task) { attempts * 100 } }
    task = MockTask.new(attempts: 3)
    result = Easyop::Scheduler.send(:_compute_backoff, task)
    assert_in_delta Time.current.to_i + 300, result.to_i, 5
  end

  MockTask = Struct.new(:attempts, keyword_init: true) do
    def max_attempts = 3
  end
end

class SchedulerCancelTest < Minitest::Test
  include EasyopTestHelper

  # Stubs the configured model class for cancel tests.
  def setup
    super
    @model_class = MockSchedulerModel.new
    Easyop.configure { |c| c.scheduler_model = 'MockSchedulerConst' }
    Object.const_set(:MockSchedulerConst, @model_class)
  end

  def teardown
    Object.send(:remove_const, :MockSchedulerConst) if Object.const_defined?(:MockSchedulerConst)
    super
  end

  def test_cancel_delegates_to_model
    @model_class.update_result = 1
    result = Easyop::Scheduler.cancel(42)
    assert result
    assert_equal({ id: 42, state: 'scheduled' }, @model_class.last_where)
    assert_equal({ state: 'canceled' }, @model_class.last_update_all)
  end

  def test_cancel_returns_false_when_no_rows_updated
    @model_class.update_result = 0
    result = Easyop::Scheduler.cancel(42)
    refute result
  end

  class MockSchedulerModel
    attr_accessor :update_result
    attr_reader   :last_where, :last_update_all

    def initialize
      @where_chain = nil
      @update_result = 1
    end

    def where(conditions)
      @last_where = conditions
      self
    end

    def update_all(conditions)
      @last_update_all = conditions
      @update_result
    end

    def constantize = self
  end
end
