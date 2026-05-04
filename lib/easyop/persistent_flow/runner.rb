# frozen_string_literal: true

module Easyop
  module PersistentFlow
    # Drives execution of a PersistentFlow step-by-step, persisting ctx across
    # async boundaries via Scheduler::Serializer.
    #
    # Two public entry points:
    #   Runner.advance!(flow_run)               — start or resume a flow
    #   Runner.execute_scheduled_step!(flow_run) — run the current async step (called by PerformStepOperation)
    module Runner
      # Internal sentinel raised by _execute_step! so advance! knows to stop immediately.
      StepFailed = Class.new(StandardError)

      HALTED_STATUSES = %w[cancelled paused failed succeeded].freeze

      # Resume the flow from its current_step_index.
      # Runs sync steps inline; schedules async steps via the Scheduler and returns.
      def self.advance!(flow_run)
        return if HALTED_STATUSES.include?(flow_run.status)

        now        = Time.current
        started_at = flow_run.respond_to?(:started_at) ? (flow_run.started_at || now) : now
        flow_run.update_columns(status: 'running', started_at: started_at)

        steps         = flow_run.flow_class.constantize._resolved_flow_steps
        ctx           = _rebuild_ctx(flow_run)
        pending_guard = nil

        steps.each_with_index do |entry, index|
          next if index < flow_run.current_step_index

          # Lambda guard placed before a step in the flow declaration
          if entry.is_a?(Proc)
            pending_guard = entry
            next
          end

          step_class, step_opts = _resolve_entry(entry)

          # Apply pending lambda guard
          if pending_guard
            unless pending_guard.call(ctx)
              _record_step(flow_run, index, step_class, 'skipped')
              flow_run.update_columns(current_step_index: index + 1)
              pending_guard = nil
              next
            end
            pending_guard = nil
          end

          # StepBuilder skip guards
          if step_opts[:skip_if]&.call(ctx)
            _record_step(flow_run, index, step_class, 'skipped')
            flow_run.update_columns(current_step_index: index + 1)
            next
          end
          if step_opts[:skip_unless] && !step_opts[:skip_unless].call(ctx)
            _record_step(flow_run, index, step_class, 'skipped')
            flow_run.update_columns(current_step_index: index + 1)
            next
          end

          # Async step — persist ctx, schedule PerformStepOperation, pause here
          if step_opts[:async]
            _persist_ctx(flow_run, ctx)
            wait   = step_opts[:wait].to_i
            run_at = now + wait
            Easyop::Scheduler.schedule_at(
              Easyop::PersistentFlow::PerformStepOperation,
              run_at,
              { flow_run_id: flow_run.id },
              tags: ["flow_run:#{flow_run.id}"]
            )
            flow_run.update_columns(current_step_index: index, status: 'running')
            return
          end

          # Sync step — run inline; stop immediately if it fails
          begin
            _execute_step!(flow_run, index, step_class, step_opts, ctx)
          rescue StepFailed
            return
          end

          flow_run.reload if flow_run.respond_to?(:reload)
          return if HALTED_STATUSES.include?(flow_run.status)
        end

        flow_run.update_columns(status: 'succeeded', finished_at: Time.current)
      end

      # Execute the async step at current_step_index (called by PerformStepOperation).
      # On success, continues advancing through remaining steps.
      def self.execute_scheduled_step!(flow_run)
        return if HALTED_STATUSES.include?(flow_run.status)

        steps = flow_run.flow_class.constantize._resolved_flow_steps
        index = flow_run.current_step_index
        entry = steps[index]

        step_class, step_opts = _resolve_entry(entry)
        ctx = _rebuild_ctx(flow_run)

        begin
          _execute_step!(flow_run, index, step_class, step_opts, ctx)
        rescue StepFailed
          return
        end

        flow_run.reload if flow_run.respond_to?(:reload)
        return if HALTED_STATUSES.include?(flow_run.status)

        advance!(flow_run)
      end

      # ── Private helpers ──────────────────────────────────────────────────────

      def self._execute_step!(flow_run, index, step_class, step_opts, ctx)
        step_record = _create_step_record(flow_run, index, step_class)

        instance = step_class.new
        instance._easyop_run(ctx, raise_on_failure: true)
        _persist_ctx(flow_run, ctx)
        flow_run.update_columns(current_step_index: index + 1)
        step_record.update_columns(status: 'completed', finished_at: Time.current)
      rescue Easyop::Ctx::Failure => e
        step_record&.update_columns(status: 'failed',
                                    error_class:   'Easyop::Ctx::Failure',
                                    error_message: e.message.to_s[0, 500],
                                    finished_at:   Time.current)
        _halt_and_skip_remaining!(flow_run, index, step_opts)
        raise StepFailed
      rescue StepFailed
        raise
      rescue => e
        step_record&.update_columns(status: 'failed',
                                    error_class:   e.class.name,
                                    error_message: e.message.to_s[0, 500],
                                    finished_at:   Time.current)
        _apply_exception_policy!(flow_run, index, step_class, step_opts, e)
        raise StepFailed
      end
      private_class_method :_execute_step!

      def self._apply_exception_policy!(flow_run, index, step_class, step_opts, _exception)
        if step_opts[:on_exception] == :cancel!
          _halt_and_skip_remaining!(flow_run, index, step_opts)
          return
        end

        cfg             = _resolve_retry_config(step_class, step_opts)
        attempts_so_far = _failed_attempts_count(flow_run, index)

        if attempts_so_far < cfg[:max_attempts]
          delay = Backoff.compute(cfg[:backoff], cfg[:wait], attempts_so_far)
          Easyop::Scheduler.schedule_at(
            Easyop::PersistentFlow::PerformStepOperation,
            Time.current + delay,
            { flow_run_id: flow_run.id },
            tags: ["flow_run:#{flow_run.id}"]
          )
        else
          _halt_and_skip_remaining!(flow_run, index, step_opts)
        end
      end
      private_class_method :_apply_exception_policy!

      # Merge step-level and operation-level retry config, with step-level winning.
      def self._resolve_retry_config(step_class, step_opts)
        if step_opts[:on_exception] == :reattempt!
          max_reattempts = step_opts[:max_reattempts] || 3
          { max_attempts: max_reattempts + 1, wait: step_opts[:wait] || 0, backoff: :constant }
        elsif step_class.respond_to?(:_async_retry_config) && step_class._async_retry_config
          step_class._async_retry_config
        else
          { max_attempts: 1, wait: 0, backoff: :constant }
        end
      end
      private_class_method :_resolve_retry_config

      def self._failed_attempts_count(flow_run, index)
        step_model = Easyop.config.persistent_flow_step_model.constantize
        step_model.where(flow_run_id: flow_run.id, step_index: index, status: 'failed').count
      end
      private_class_method :_failed_attempts_count

      # Mark the flow as failed and optionally record skipped rows for all remaining steps.
      def self._halt_and_skip_remaining!(flow_run, failed_index, step_opts)
        flow_run.update_columns(status: 'failed', finished_at: Time.current)
        _mark_remaining_steps_skipped!(flow_run, failed_index) if step_opts[:blocking]
      end
      private_class_method :_halt_and_skip_remaining!

      # Insert a 'skipped' EasyFlowRunStep row for every step that comes after failed_index.
      def self._mark_remaining_steps_skipped!(flow_run, failed_index)
        steps      = flow_run.flow_class.constantize._resolved_flow_steps
        step_model = Easyop.config.persistent_flow_step_model.constantize
        steps.each_with_index do |entry, idx|
          next if idx <= failed_index
          next if entry.is_a?(Proc)
          step_class, _opts = _resolve_entry(entry)
          step_model.create!(
            flow_run_id:     flow_run.id,
            step_index:      idx,
            operation_class: step_class.name,
            status:          'skipped',
            attempt:         0,
            started_at:      Time.current,
            finished_at:     Time.current,
            error_message:   'skipped due to upstream blocking failure'
          )
        end
      end
      private_class_method :_mark_remaining_steps_skipped!

      def self._resolve_entry(entry)
        if defined?(Easyop::Operation::StepBuilder) && entry.is_a?(Easyop::Operation::StepBuilder)
          [entry.klass, entry.to_step_config]
        else
          [entry, {}]
        end
      end
      private_class_method :_resolve_entry

      def self._rebuild_ctx(flow_run)
        attrs = Easyop::Scheduler::Serializer.deserialize(flow_run.context_data)
        Easyop::Ctx.build(attrs)
      end
      private_class_method :_rebuild_ctx

      def self._persist_ctx(flow_run, ctx)
        flow_run.update_columns(
          context_data: Easyop::Scheduler::Serializer.serialize(ctx.to_h)
        )
      end
      private_class_method :_persist_ctx

      def self._record_step(flow_run, index, step_class, status)
        step_model = Easyop.config.persistent_flow_step_model.constantize
        step_model.create!(
          flow_run_id:     flow_run.id,
          step_index:      index,
          operation_class: step_class.name,
          status:          status,
          attempt:         0,
          started_at:      Time.current,
          finished_at:     Time.current
        )
      end
      private_class_method :_record_step

      def self._create_step_record(flow_run, index, step_class)
        step_model = Easyop.config.persistent_flow_step_model.constantize
        step_model.create!(
          flow_run_id:     flow_run.id,
          step_index:      index,
          operation_class: step_class.name,
          status:          'running',
          attempt:         0,
          started_at:      Time.current
        )
      end
      private_class_method :_create_step_record
    end

    # An Easyop::Operation the Scheduler invokes to execute a scheduled async
    # step in a PersistentFlow.  Keeps PerformStepJob as an optional ActiveJob
    # entry point for queues that prefer that model.
    class PerformStepOperation
      include Easyop::Operation

      def call
        flow_run_class = Easyop.config.persistent_flow_model.constantize
        flow_run       = flow_run_class.find(ctx[:flow_run_id])
        Runner.execute_scheduled_step!(flow_run)
      end
    end
  end
end
