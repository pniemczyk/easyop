# frozen_string_literal: true

module Easyop
  module Testing
    # Helpers for testing Easyop::Plugins::Async.
    #
    # Uses a thread-local spy hook that the Async plugin checks before enqueuing.
    # Activate with capture_async { } or perform_async_inline { }.
    #
    # --- capture mode: records call_async calls, does NOT enqueue real jobs ---
    #
    #   calls = capture_async do
    #     Newsletter::SendBroadcast.call_async(email: "a@b.com", wait: 5.minutes)
    #   end
    #   assert_async_enqueued calls, Newsletter::SendBroadcast, with: { email: "a@b.com" }
    #   assert_async_wait     calls, Newsletter::SendBroadcast, wait: 5.minutes
    #   assert_async_queue    calls, Newsletter::SendBroadcast, queue: "operations"
    #
    # --- inline mode: call_async becomes synchronous call, useful for integration ---
    #
    #   perform_async_inline { Newsletter::SendBroadcast.call_async(email: "a@b.com") }
    #   assert Subscription.confirmed.exists?(email: "a@b.com")
    #
    module AsyncAssertions
      # Capture all call_async invocations within the block.
      # Jobs are NOT enqueued. Returns array of captured calls.
      #
      # Each entry is a Hash:
      #   { operation: <Class>, attrs: <Hash>, queue: <String|nil>,
      #     wait: <Duration|nil>, wait_until: <Time|nil> }
      def capture_async(&block)
        Thread.current[:_easyop_async_capture]      = []
        Thread.current[:_easyop_async_capture_only] = true
        block.call
        Thread.current[:_easyop_async_capture].dup
      ensure
        Thread.current[:_easyop_async_capture]      = nil
        Thread.current[:_easyop_async_capture_only] = nil
      end

      # Run call_async calls synchronously within the block (no job queue).
      # The operation is called immediately with the same attrs as it would
      # receive when the job eventually performs, including AR rehydration.
      def perform_async_inline(&block)
        Thread.current[:_easyop_async_capture]      = []
        Thread.current[:_easyop_async_capture_only] = false
        block.call
      ensure
        Thread.current[:_easyop_async_capture]      = nil
        Thread.current[:_easyop_async_capture_only] = nil
      end

      # Assert at least one call_async was captured for +op+.
      #
      # @param calls [Array<Hash>]  return value of capture_async {}
      # @param op    [Class]        operation class expected to be enqueued
      # @param with  [Hash, nil]    optional attrs subset to verify
      def assert_async_enqueued(calls, op, with: nil)
        matching = calls.select { |c| c[:operation] == op }
        _easyop_assert matching.any?,
          "Expected #{op.name} to be enqueued async but it wasn't. " \
          "Enqueued: #{calls.map { |c| c[:operation].name }.inspect}"

        return unless with

        attrs_ok = matching.any? do |c|
          with.all? { |k, v| c[:attrs][k.to_sym] == v || c[:attrs][k.to_s] == v }
        end
        _easyop_assert attrs_ok,
          "#{op.name} was enqueued but not with attrs #{with.inspect}. " \
          "Actual: #{matching.map { |c| c[:attrs] }.inspect}"
      end

      # Assert no call_async was captured (for all operations, or one specific op).
      def assert_no_async_enqueued(calls, op = nil)
        relevant = op ? calls.select { |c| c[:operation] == op } : calls
        _easyop_assert relevant.empty?,
          "Expected no async calls#{op ? " for #{op.name}" : ""} but got: " \
          "#{relevant.map { |c| c[:operation].name }.inspect}"
      end

      # Assert the queue used for +op+.
      #   assert_async_queue calls, MyOp, queue: "low_priority"
      def assert_async_queue(calls, op, queue:)
        matching = calls.select { |c| c[:operation] == op }
        _easyop_assert matching.any?, "#{op.name} was not enqueued async"
        _easyop_assert matching.any? { |c| c[:queue].to_s == queue.to_s },
          "#{op.name} not enqueued on queue #{queue.inspect}. " \
          "Actual queues: #{matching.map { |c| c[:queue].inspect }.inspect}"
      end

      # Assert the wait/wait_until used for +op+.
      #   assert_async_wait calls, MyOp, wait: 5.minutes
      #   assert_async_wait calls, MyOp, wait_until: Date.tomorrow.noon
      def assert_async_wait(calls, op, wait: nil, wait_until: nil)
        matching = calls.select { |c| c[:operation] == op }
        _easyop_assert matching.any?, "#{op.name} was not enqueued async"

        if wait
          _easyop_assert matching.any? { |c| c[:wait] == wait },
            "#{op.name} not enqueued with wait: #{wait.inspect}. " \
            "Actual: #{matching.map { |c| c[:wait].inspect }.inspect}"
        end
        if wait_until
          _easyop_assert matching.any? { |c| c[:wait_until] == wait_until },
            "#{op.name} not enqueued with wait_until: #{wait_until.inspect}"
        end
      end
    end
  end
end
