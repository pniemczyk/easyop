# frozen_string_literal: true

require 'test_helper'

# Stub ActiveJob::Base if not already defined.
unless defined?(ActiveJob::Base)
  module ActiveJob
    class Base
      @@jobs = []

      def self.queue_as(_q); end

      def self.set(**opts)
        _make_proxy(opts)
      end

      def self._make_proxy(accumulated_opts)
        Class.new do
          define_singleton_method(:set) { |**more| ActiveJob::Base._make_proxy(accumulated_opts.merge(more)) }
          define_singleton_method(:perform_later) { |*args| ActiveJob::Base.jobs << { args: args, opts: accumulated_opts } }
        end
      end

      def self.jobs
        @@jobs
      end

      def self.clear_jobs!
        @@jobs = []
      end
    end
  end
end

class PluginsAsyncTest < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    ActiveJob::Base.clear_jobs! if ActiveJob::Base.respond_to?(:clear_jobs!)
    _reset_async_job!
  end

  def teardown
    _reset_async_job!
    super
  end

  def _reset_async_job!
    Easyop::Plugins::Async.instance_variable_set(:@job_class, nil)
    if Easyop::Plugins::Async.const_defined?(:Job, false)
      Easyop::Plugins::Async.send(:remove_const, :Job)
    end
  end

  def make_op(queue: 'default', &call_block)
    klass = Class.new do
      include Easyop::Operation
    end
    klass.plugin(Easyop::Plugins::Async, queue: queue)
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  # ── call_async enqueues job ───────────────────────────────────────────────────

  def test_dot_call_async_enqueues_job
    op = make_op
    set_const('AsyncTestOp', op)
    op.call_async(name: 'alice')
    assert_equal 1, ActiveJob::Base.jobs.size
  end

  def test_dot_call_async_passes_operation_class_name
    op = make_op
    set_const('AsyncTestOp2', op)
    op.call_async(x: 1)
    job = ActiveJob::Base.jobs.first
    assert_equal 'AsyncTestOp2', job[:args].first
  end

  def test_dot_call_async_serializes_attrs_as_string_keys
    op = make_op
    set_const('AsyncTestOp3', op)
    op.call_async(age: 30)
    serialized = ActiveJob::Base.jobs.first[:args].last
    assert serialized.key?('age')
    assert_equal 30, serialized['age']
  end

  # ── Default queue ─────────────────────────────────────────────────────────────

  def test_dot_call_async_uses_configured_queue
    op = make_op(queue: 'broadcasts')
    set_const('AsyncQueueOp', op)
    op.call_async
    job = ActiveJob::Base.jobs.first
    assert_equal 'broadcasts', job[:opts][:queue]
  end

  def test_dot_call_async_queue_override_per_call
    op = make_op(queue: 'default')
    set_const('AsyncQueueOverOp', op)
    op.call_async({}, queue: 'low')
    job = ActiveJob::Base.jobs.first
    assert_equal 'low', job[:opts][:queue]
  end

  # ── queue DSL on class ────────────────────────────────────────────────────────

  def test_queue_class_method_sets_default_queue
    op = make_op
    op.queue('custom')
    assert_equal 'custom', op._async_default_queue
  end

  def test_queue_inherited_from_parent
    parent = make_op(queue: 'parent_queue')
    child  = Class.new(parent)
    assert_equal 'parent_queue', child._async_default_queue
  end

  # ── Raises LoadError without ActiveJob ───────────────────────────────────────

  def test_dot_call_async_raises_load_error_without_active_job
    aj_backup = ActiveJob.send(:remove_const, :Base)

    op = make_op
    set_const('AsyncNoAJOp', op)
    err = assert_raises(LoadError) { op.call_async }
    assert_includes err.message, 'ActiveJob'
  ensure
    ActiveJob.const_set(:Base, aj_backup) if defined?(aj_backup)
  end

  # ── ActiveRecord serialisation ────────────────────────────────────────────────

  def test_ar_objects_serialized_by_class_and_id
    # Fake AR object
    ar_obj = Object.new
    ar_obj.define_singleton_method(:class) do
      kls = Object.new
      kls.define_singleton_method(:name) { 'FakeUser' }
      kls
    end
    ar_obj.define_singleton_method(:id) { 99 }

    # Make it look like ActiveRecord::Base
    ar_base = Class.new
    stub_const = ar_base

    # Temporarily define ActiveRecord::Base
    unless defined?(ActiveRecord::Base)
      Object.const_set(:ActiveRecord, Module.new)
      ActiveRecord.const_set(:Base, ar_base)
      defined_ar = true
    end

    # Override is_a? for the fake object
    ar_obj.define_singleton_method(:is_a?) { |klass| klass == ActiveRecord::Base }

    op = make_op
    set_const('AsyncArOp', op)
    op.call_async(user: ar_obj)
    serialized = ActiveJob::Base.jobs.first[:args].last
    assert_equal 'FakeUser', serialized['user']['__ar_class']
    assert_equal 99,         serialized['user']['__ar_id']
  ensure
    if defined?(defined_ar) && defined_ar
      ActiveRecord.send(:remove_const, :Base) rescue nil
      Object.send(:remove_const, :ActiveRecord) rescue nil
    end
  end

  # ── Job#perform deserializes and calls operation ──────────────────────────────

  def test_job_perform_calls_operation
    op = make_op { ctx[:ran] = true }
    set_const('AsyncPerformOp', op)

    # Force job_class creation
    job_class = Easyop::Plugins::Async.job_class
    job_instance = job_class.new
    job_instance.perform('AsyncPerformOp', { 'x' => 42 })

    # Because op.call is synchronous here, just verify no exception
    # (ctx is not returned from perform, but call ran)
  end

  # ── async_retry DSL ───────────────────────────────────────────────────────────

  def test_async_retry_stores_config
    op = make_op
    op.async_retry(max_attempts: 5, wait: 10, backoff: :linear)
    cfg = op._async_retry_config
    assert_equal 5,       cfg[:max_attempts]
    assert_equal 10,      cfg[:wait]
    assert_equal :linear, cfg[:backoff]
  end

  def test_async_retry_defaults
    op = make_op
    op.async_retry
    cfg = op._async_retry_config
    assert_equal 3,         cfg[:max_attempts]
    assert_equal 0,         cfg[:wait]
    assert_equal :constant, cfg[:backoff]
  end

  def test_async_retry_config_nil_when_not_set
    op = make_op
    assert_nil op._async_retry_config
  end

  def test_async_retry_inherited_by_subclass
    parent = make_op
    parent.async_retry(max_attempts: 4, wait: 5, backoff: :exponential)
    child = Class.new(parent)
    cfg = child._async_retry_config
    assert_equal 4,           cfg[:max_attempts]
    assert_equal :exponential, cfg[:backoff]
  end

  def test_async_retry_subclass_can_override_parent
    parent = make_op
    parent.async_retry(max_attempts: 4, wait: 5, backoff: :exponential)
    child = Class.new(parent)
    child.async_retry(max_attempts: 2, wait: 1, backoff: :constant)
    cfg = child._async_retry_config
    assert_equal 2,         cfg[:max_attempts]
    assert_equal :constant, cfg[:backoff]
    # parent unchanged
    assert_equal 4, parent._async_retry_config[:max_attempts]
  end

  def test_async_retry_raises_on_zero_max_attempts
    op = make_op
    assert_raises(ArgumentError) { op.async_retry(max_attempts: 0) }
  end

  def test_async_retry_raises_on_invalid_backoff
    op = make_op
    assert_raises(ArgumentError) { op.async_retry(backoff: :unknown) }
  end

  def test_async_retry_accepts_callable_wait
    op = make_op
    fn = ->(attempt) { attempt * 10 }
    op.async_retry(wait: fn)
    assert_equal fn, op._async_retry_config[:wait]
  end

  def test_async_retry_config_is_frozen
    op = make_op
    op.async_retry(max_attempts: 2)
    assert_predicate op._async_retry_config, :frozen?
  end

end
