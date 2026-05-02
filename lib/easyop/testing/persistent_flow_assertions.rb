# frozen_string_literal: true

module Easyop
  module Testing
    # Assertions and helpers for testing PersistentFlow orchestrations.
    #
    # Included automatically when `Easyop::PersistentFlow` is defined and
    # `Easyop::Testing` is included in your test class.
    #
    # Key helpers:
    #   speedrun_flow(flow_run)                    — drain async steps synchronously
    #   assert_flow_status(flow_run, :succeeded)   — assert current status
    #   assert_step_completed(flow_run, MyOp)      — assert a step completed
    #   assert_step_skipped(flow_run, MyOp)        — assert a step was skipped
    module PersistentFlowAssertions
      # Advance all scheduled async steps inline until the flow reaches a
      # terminal state or there are no more pending tasks.
      # Calls Easyop::Scheduler.tick_now! in a loop until the flow is terminal.
      def speedrun_flow(flow_run, max_ticks: 50)
        ticks = 0
        flow_run_class = flow_run.class

        until flow_run.reload.terminal? || ticks >= max_ticks
          Easyop::Scheduler.tick_now!
          flow_run.reload
          ticks += 1
        end

        flow_run
      end

      # Assert the flow run is in the expected status.
      #
      # @param flow_run [EasyFlowRun]
      # @param expected_status [String, Symbol]
      def assert_flow_status(flow_run, expected_status, msg = nil)
        actual = flow_run.reload.status
        message = msg || "Expected flow #{flow_run.id} to have status " \
                         "#{expected_status.inspect}, got #{actual.inspect}"
        assert_equal expected_status.to_s, actual, message
      end

      # Assert that a specific step completed successfully.
      #
      # @param flow_run [EasyFlowRun]
      # @param step_class [Class] the operation class
      def assert_step_completed(flow_run, step_class, msg = nil)
        step_model = Easyop.config.persistent_flow_step_model.constantize
        exists = step_model.where(flow_run_id: flow_run.id,
                                  operation_class: step_class.name,
                                  status: 'completed').exists?
        message = msg || "Expected step #{step_class.name} to have completed " \
                         "in flow run #{flow_run.id}"
        assert exists, message
      end

      # Assert that a specific step was skipped.
      #
      # @param flow_run [EasyFlowRun]
      # @param step_class [Class] the operation class
      def assert_step_skipped(flow_run, step_class, msg = nil)
        step_model = Easyop.config.persistent_flow_step_model.constantize
        exists = step_model.where(flow_run_id: flow_run.id,
                                  operation_class: step_class.name,
                                  status: 'skipped').exists?
        message = msg || "Expected step #{step_class.name} to have been skipped " \
                         "in flow run #{flow_run.id}"
        assert exists, message
      end

      # Assert that a specific step failed.
      #
      # @param flow_run [EasyFlowRun]
      # @param step_class [Class] the operation class
      def assert_step_failed(flow_run, step_class, msg = nil)
        step_model = Easyop.config.persistent_flow_step_model.constantize
        exists = step_model.where(flow_run_id: flow_run.id,
                                  operation_class: step_class.name,
                                  status: 'failed').exists?
        message = msg || "Expected step #{step_class.name} to have failed " \
                         "in flow run #{flow_run.id}"
        assert exists, message
      end
    end
  end
end
