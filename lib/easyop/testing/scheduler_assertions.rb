# frozen_string_literal: true

module Easyop
  module Testing
    module SchedulerAssertions
      # Assert that exactly one task was scheduled for the given operation.
      #
      # @example
      #   assert_scheduled MyOperation, attrs: { user_id: 1 }, tags: ['user:1']
      def assert_scheduled(operation_class, attrs: nil, tags: nil, run_at: nil, msg: nil)
        model = Easyop.config.scheduler_model.constantize
        scope = model.where(state: 'scheduled', operation_class: operation_class.name)

        if attrs
          serialized = Easyop::Scheduler::Serializer.serialize(attrs)
          scope = scope.where(ctx_data: serialized)
        end

        if tags
          tag_list = Array(tags)
          tag_list.each do |tag|
            scope = scope.where('tags LIKE ?', "%#{tag}%")
          end
        end

        if run_at
          scope = scope.where('run_at >= ? AND run_at <= ?', run_at - 5.seconds, run_at + 5.seconds)
        end

        count = scope.count
        message = msg || "Expected 1 scheduled task for #{operation_class.name}, found #{count}"
        assert_equal 1, count, message
      end

      # Assert no tasks are scheduled for the given operation.
      def assert_no_scheduled(operation_class, msg: nil)
        model = Easyop.config.scheduler_model.constantize
        count = model.where(state: 'scheduled', operation_class: operation_class.name).count
        message = msg || "Expected no scheduled tasks for #{operation_class.name}, found #{count}"
        assert_equal 0, count, message
      end

      # Cancel all scheduled tasks and run any that are due (state='scheduled', run_at <= now).
      # Useful in tests that don't want to worry about tick timing.
      def flush_scheduler!
        Easyop::Scheduler.tick_now!
      end

      # Cancel all scheduled tasks in the test — call in teardown to prevent
      # tasks from leaking between tests.
      def clear_scheduler!
        Easyop.config.scheduler_model.constantize
               .where(state: %w[scheduled running])
               .update_all(state: 'canceled')
      end
    end
  end
end
