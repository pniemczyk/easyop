# frozen_string_literal: true

module Easyop
  module Plugins
    # Adds class-level scheduling helpers to an operation.
    #
    # Usage:
    #   class Reports::GeneratePDF < ApplicationOperation
    #     plugin Easyop::Plugins::Scheduler, max_attempts: 5
    #   end
    #
    #   # One-shot
    #   Reports::GeneratePDF.schedule_in(1.hour, report_id: 42)
    #   Reports::GeneratePDF.schedule_at(Date.tomorrow.noon, report_id: 42)
    #
    #   # Recurring (requires fugit gem)
    #   Reports::GeneratePDF.schedule_cron('0 9 * * *', account: account)
    module Scheduler
      def self.install(base, max_attempts: nil, backoff: nil, **_options)
        base.extend(ClassMethods)
        base.instance_variable_set(:@_scheduler_max_attempts, max_attempts)
        base.instance_variable_set(:@_scheduler_backoff, backoff)
      end

      module ClassMethods
        def schedule_at(time, attrs = {}, tags: [], dedup_key: nil)
          Easyop::Scheduler.schedule_at(
            self, time, attrs,
            tags: tags, dedup_key: dedup_key,
            max_attempts: _scheduler_max_attempts
          )
        end

        def schedule_in(duration, attrs = {}, tags: [], dedup_key: nil)
          Easyop::Scheduler.schedule_in(
            self, duration, attrs,
            tags: tags, dedup_key: dedup_key,
            max_attempts: _scheduler_max_attempts
          )
        end

        def schedule_cron(expression, attrs = {}, tags: [])
          Easyop::Scheduler.schedule_cron(
            self, expression, attrs,
            tags: tags,
            max_attempts: _scheduler_max_attempts
          )
        end

        def schedule(attrs = {}, tags: [], dedup_key: nil)
          Easyop::Scheduler.schedule(
            self, attrs,
            tags: tags, dedup_key: dedup_key,
            max_attempts: _scheduler_max_attempts
          )
        end

        def _scheduler_max_attempts
          @_scheduler_max_attempts ||
            (superclass.respond_to?(:_scheduler_max_attempts) ? superclass._scheduler_max_attempts : nil)
        end
      end
    end
  end
end
