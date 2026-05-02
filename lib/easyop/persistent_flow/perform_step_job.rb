# frozen_string_literal: true

if defined?(ActiveJob::Base)
  module Easyop
    module PersistentFlow
      # ActiveJob that executes a scheduled async step in a PersistentFlow.
      # Enqueued by Runner.advance! when an async step is encountered.
      class PerformStepJob < ActiveJob::Base
        queue_as :easyop_persistent_flow

        self.enqueue_after_transaction_commit = :never if respond_to?(:enqueue_after_transaction_commit=)

        def perform(flow_run_id)
          flow_run_class = Easyop.config.persistent_flow_model.constantize
          flow_run       = flow_run_class.find(flow_run_id)
          Easyop::PersistentFlow::Runner.execute_scheduled_step!(flow_run)
        end
      end
    end
  end
end
