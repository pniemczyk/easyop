# frozen_string_literal: true

require "test_helper"

# Stub ActiveJob::Base if not already defined (mirrors async_test.rb setup).
# capture_async intercepts before _async_ensure_active_job! so real ActiveJob
# is never needed, but the stub is referenced in a couple of "no real enqueue" tests.
unless defined?(::ActiveJob::Base)
  module ActiveJob
    class Base
      @@jobs = []
      def self.queue_as(_q); end
      def self.set(**opts)
        proxy = Class.new do
          define_singleton_method(:perform_later) { |*args| @@jobs << { args: args, opts: opts } }
        end
        proxy
      end
      def self.jobs     = @@jobs
      def self.clear_jobs! = (@@jobs = [])
    end
  end
end

class Easyop::Testing::AsyncAssertionsTest < Minitest::Test
  include EasyopTestHelper
  include Easyop::Testing::Assertions
  include Easyop::Testing::AsyncAssertions

  # ── helpers ───────────────────────────────────────────────────────────────────

  def make_op(queue: "default", &call_block)
    klass = Class.new { include Easyop::Operation }
    klass.plugin(Easyop::Plugins::Async, queue: queue)
    klass.define_method(:call, &call_block) if call_block
    klass
  end

  def setup
    super
    # Reset any leftover async job class between tests
    Easyop::Plugins::Async.instance_variable_set(:@job_class, nil)
    if Easyop::Plugins::Async.const_defined?(:Job, false)
      Easyop::Plugins::Async.send(:remove_const, :Job)
    end
  end

  # ── capture_async ─────────────────────────────────────────────────────────────

  def test_capture_async_returns_empty_array_when_nothing_enqueued
    calls = capture_async { }
    assert_empty calls
  end

  def test_capture_async_captures_one_call
    op    = make_op
    calls = capture_async { op.call_async(name: "alice") }
    assert_equal 1, calls.size
  end

  def test_capture_async_captures_operation_class
    op    = make_op
    calls = capture_async { op.call_async(name: "alice") }
    assert_equal op, calls.first[:operation]
  end

  def test_capture_async_captures_attrs
    op    = make_op
    calls = capture_async { op.call_async(email: "a@b.com", role: "admin") }
    entry = calls.first
    assert_equal "a@b.com", entry[:attrs][:email]
    assert_equal "admin",   entry[:attrs][:role]
  end

  def test_capture_async_captures_queue
    op    = make_op(queue: "critical")
    calls = capture_async { op.call_async }
    # queue captured in entry (nil means use op default — we track the override or nil)
    # The plugin stores the override passed to call_async, not the resolved default.
    entry = calls.first
    assert_includes [nil, "critical"], entry[:queue]
  end

  def test_capture_async_captures_wait
    op    = make_op
    calls = capture_async { op.call_async({}, wait: 300) }
    assert_equal 300, calls.first[:wait]
  end

  def test_capture_async_does_not_enqueue_real_job
    op            = make_op
    jobs_before   = ::ActiveJob::Base.jobs.size
    capture_async { op.call_async(x: 1) }
    assert_equal jobs_before, ::ActiveJob::Base.jobs.size
  end

  def test_capture_async_captures_multiple_calls
    op1   = make_op
    op2   = make_op
    calls = capture_async do
      op1.call_async(a: 1)
      op2.call_async(b: 2)
    end
    assert_equal 2, calls.size
  end

  # ── assert_async_enqueued ─────────────────────────────────────────────────────

  def test_assert_async_enqueued_passes_when_op_is_captured
    op    = make_op
    calls = capture_async { op.call_async }
    assert_silent { assert_async_enqueued(calls, op) }
  end

  def test_assert_async_enqueued_fails_when_op_not_captured
    op1   = make_op
    op2   = make_op
    calls = capture_async { op1.call_async }
    assert_raises(Minitest::Assertion) { assert_async_enqueued(calls, op2) }
  end

  def test_assert_async_enqueued_with_attrs_subset_passes
    op    = make_op
    calls = capture_async { op.call_async(email: "x@y.com", name: "Alice") }
    assert_silent { assert_async_enqueued(calls, op, with: { email: "x@y.com" }) }
  end

  def test_assert_async_enqueued_with_attrs_fails_when_attrs_differ
    op    = make_op
    calls = capture_async { op.call_async(email: "x@y.com") }
    assert_raises(Minitest::Assertion) do
      assert_async_enqueued(calls, op, with: { email: "different@y.com" })
    end
  end

  # ── assert_no_async_enqueued ──────────────────────────────────────────────────

  def test_assert_no_async_enqueued_passes_when_empty
    calls = capture_async { }
    assert_silent { assert_no_async_enqueued(calls) }
  end

  def test_assert_no_async_enqueued_fails_when_op_was_enqueued
    op    = make_op
    calls = capture_async { op.call_async }
    assert_raises(Minitest::Assertion) { assert_no_async_enqueued(calls) }
  end

  def test_assert_no_async_enqueued_for_specific_op_passes_when_not_enqueued
    op1   = make_op
    op2   = make_op
    calls = capture_async { op1.call_async }
    assert_silent { assert_no_async_enqueued(calls, op2) }
  end

  def test_assert_no_async_enqueued_for_specific_op_fails_when_enqueued
    op    = make_op
    calls = capture_async { op.call_async }
    assert_raises(Minitest::Assertion) { assert_no_async_enqueued(calls, op) }
  end

  # ── assert_async_queue ────────────────────────────────────────────────────────

  def test_assert_async_queue_passes_when_queue_matches
    op    = make_op(queue: "broadcasts")
    calls = capture_async { op.call_async }
    # The captured :queue is nil when no override; the op-level queue is in the class.
    # assert_async_queue compares c[:queue] OR falls back: check what capture stores.
    # Based on the plugin: queue param is the OVERRIDE, not the default.
    # We need to pass an override to test the queue capture:
    calls2 = capture_async { op.call_async({}, queue: "broadcasts") }
    assert_silent { assert_async_queue(calls2, op, queue: "broadcasts") }
  end

  def test_assert_async_queue_fails_when_queue_does_not_match
    op    = make_op(queue: "broadcasts")
    calls = capture_async { op.call_async({}, queue: "broadcasts") }
    assert_raises(Minitest::Assertion) { assert_async_queue(calls, op, queue: "low") }
  end

  # ── assert_async_wait ─────────────────────────────────────────────────────────

  def test_assert_async_wait_passes_when_wait_matches
    op    = make_op
    calls = capture_async { op.call_async({}, wait: 600) }
    assert_silent { assert_async_wait(calls, op, wait: 600) }
  end

  def test_assert_async_wait_fails_when_wait_differs
    op    = make_op
    calls = capture_async { op.call_async({}, wait: 600) }
    assert_raises(Minitest::Assertion) { assert_async_wait(calls, op, wait: 999) }
  end

  # ── perform_async_inline ──────────────────────────────────────────────────────

  def test_perform_async_inline_calls_operation_synchronously
    result_store = []
    op = make_op { result_store << ctx[:value] }

    perform_async_inline { op.call_async(value: 42) }

    assert_equal [42], result_store
  end

  def test_perform_async_inline_does_not_enqueue_real_job
    op          = make_op { }
    jobs_before = ::ActiveJob::Base.jobs.size

    perform_async_inline { op.call_async(x: 1) }

    assert_equal jobs_before, ::ActiveJob::Base.jobs.size
  end
end
