# frozen_string_literal: true

module Easyop
  module Scheduler
    # AR model mixin. Included into the configured model class at boot.
    # The concrete class (default: EasyScheduledTask) is created by the generator.
    module ScheduledTaskModel
      STATES = %w[scheduled running completed failed dead canceled].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Claim and return due tasks, skipping locked rows (Postgres) or using
        # optimistic locking (SQLite / MySQL).
        def claim_due_batch(batch_size:, lock_window:, worker_id:)
          adapter = connection.adapter_name.downcase

          if adapter.include?('postgresql') || adapter.include?('postgis')
            _claim_batch_postgres(batch_size: batch_size, lock_window: lock_window,
                                  worker_id: worker_id)
          else
            _claim_batch_optimistic(batch_size: batch_size, lock_window: lock_window,
                                    worker_id: worker_id)
          end
        end

        private

        def _claim_batch_postgres(batch_size:, lock_window:, worker_id:)
          claimed = []
          transaction do
            rows = where(state: 'scheduled')
                     .where('run_at <= ?', Time.current)
                     .order(:run_at)
                     .limit(batch_size)
                     .lock('FOR UPDATE SKIP LOCKED')
                     .to_a

            now = Time.current
            rows.each do |task|
              task.update_columns(
                state:        'running',
                claimed_at:   now,
                claimed_by:   worker_id,
                locked_until: now + lock_window
              )
              claimed << task
            end
          end
          claimed
        end

        def _claim_batch_optimistic(batch_size:, lock_window:, worker_id:)
          claimed = []
          candidates = where(state: 'scheduled')
                         .where('run_at <= ?', Time.current)
                         .order(:run_at)
                         .limit(batch_size)
                         .to_a

          candidates.each do |task|
            now = Time.current
            rows_updated = where(id: task.id, state: 'scheduled', lock_version: task.lock_version)
                             .update_all(
                               state:        'running',
                               claimed_at:   now,
                               claimed_by:   worker_id,
                               locked_until: now + lock_window,
                               lock_version: task.lock_version + 1
                             )
            claimed << task.reload if rows_updated == 1
          end
          claimed
        end
      end

      # ── Instance methods ────────────────────────────────────────────────────

      def scheduled?  = state == 'scheduled'
      def running?    = state == 'running'
      def completed?  = state == 'completed'
      def dead?       = state == 'dead'
      def canceled?   = state == 'canceled'

      def cancel!
        self.class.where(id: id, state: 'scheduled')
                  .update_all(state: 'canceled') == 1
      end

      def parsed_tags
        return [] if tags.nil? || tags.empty?
        JSON.parse(tags)
      rescue JSON::ParserError
        []
      end
    end
  end
end
