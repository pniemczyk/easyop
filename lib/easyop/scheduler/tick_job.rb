# frozen_string_literal: true

module Easyop
  module Scheduler
    # Recurring ActiveJob that claims and executes due scheduled tasks.
    #
    # Register as a recurring job in your adapter's configuration:
    #
    #   # SolidQueue (config/recurring.yml)
    #   easyop_scheduler_tick:
    #     class: Easyop::Scheduler::TickJob
    #     schedule: every minute
    #     queue: easyop_scheduler
    #
    #   # Sidekiq-Cron (sidekiq.yml)
    #   - name: Easyop Scheduler Tick
    #     cron: '* * * * *'
    #     class: Easyop::Scheduler::TickJob
    #
    #   # GoodJob
    #   GoodJob.configure { |c| c.cron = { easyop_tick: { cron: '* * * * *', class: 'Easyop::Scheduler::TickJob' } } }

    if defined?(ActiveJob::Base)
      class TickJob < ActiveJob::Base
        queue_as :easyop_scheduler

        self.enqueue_after_transaction_commit = :never if respond_to?(:enqueue_after_transaction_commit=)

        def perform
          Easyop::Scheduler.recover_stuck!
          Easyop::Scheduler.run_batch!
        end
      end
    end
  end
end
