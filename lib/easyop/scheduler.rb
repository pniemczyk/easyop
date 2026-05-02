# frozen_string_literal: true

require 'json'
require 'socket'
require_relative 'scheduler/serializer'
require_relative 'scheduler/scheduled_task_model'
require_relative 'scheduler/tick_job'

module Easyop
  # DB-backed scheduler. Stores scheduled tasks as rows in easy_scheduled_tasks
  # and executes them via a recurring TickJob.
  #
  # Opt-in — add to your application's boot sequence:
  #   require "easyop/scheduler"
  #
  # Usage:
  #   task = Easyop::Scheduler.schedule_in(MyOperation, 1.hour, { user: user })
  #   Easyop::Scheduler.cancel(task.id)
  #   Easyop::Scheduler.cancel_by_tag("user:#{user.id}")
  module Scheduler
    # ── Public scheduling API ────────────────────────────────────────────────

    def self.schedule_at(operation_class, time, attrs = {}, tags: [], dedup_key: nil,
                         max_attempts: nil)
      _create_task(
        operation_class: operation_class.name,
        ctx_data:        Serializer.serialize(attrs),
        run_at:          time,
        tags:            JSON.dump(Array(tags)),
        dedup_key:       dedup_key,
        max_attempts:    max_attempts || Easyop.config.scheduler_default_max_attempts
      )
    end

    def self.schedule_in(operation_class, duration, attrs = {}, tags: [], dedup_key: nil,
                         max_attempts: nil)
      schedule_at(operation_class, Time.current + duration, attrs,
                  tags: tags, dedup_key: dedup_key, max_attempts: max_attempts)
    end

    # Schedule a recurring task using a cron expression (requires the `fugit` gem).
    def self.schedule_cron(operation_class, cron_expression, attrs = {}, tags: [],
                           max_attempts: nil)
      next_time = _next_cron_time(cron_expression)
      raise ArgumentError, "Invalid cron expression: #{cron_expression.inspect}" unless next_time

      _create_task(
        operation_class: operation_class.name,
        ctx_data:        Serializer.serialize(attrs),
        run_at:          next_time,
        cron:            cron_expression,
        tags:            JSON.dump(Array(tags)),
        max_attempts:    max_attempts || Easyop.config.scheduler_default_max_attempts
      )
    end

    # Schedule for the next tick (immediate execution at next tick cycle).
    def self.schedule(operation_class, attrs = {}, tags: [], dedup_key: nil, max_attempts: nil)
      schedule_at(operation_class, Time.current, attrs,
                  tags: tags, dedup_key: dedup_key, max_attempts: max_attempts)
    end

    # ── Cancellation ─────────────────────────────────────────────────────────

    def self.cancel(task_id)
      _model_class.where(id: task_id, state: 'scheduled')
                  .update_all(state: 'canceled') == 1
    end

    def self.cancel_by_tag(tag)
      adapter = _adapter_name
      if adapter.include?('postgresql') || adapter.include?('postgis')
        _model_class.where(state: 'scheduled')
                    .where("tags::jsonb @> ?", JSON.dump([tag]))
                    .update_all(state: 'canceled')
      else
        _model_class.where(state: 'scheduled')
                    .where('tags LIKE ?', "%#{tag.gsub('%', '\\%')}%")
                    .update_all(state: 'canceled')
      end
    end

    def self.cancel_by_operation(operation_class)
      _model_class.where(state: 'scheduled', operation_class: operation_class.name)
                  .update_all(state: 'canceled')
    end

    # ── Query ────────────────────────────────────────────────────────────────

    def self.peek(filter = {})
      scope = _model_class.where(state: 'scheduled')
      scope = scope.where(operation_class: filter[:operation].name) if filter[:operation]
      scope = scope.where('tags LIKE ?', "%#{filter[:tag]}%") if filter[:tag]
      scope.order(:run_at)
    end

    # ── Internal execution (called by TickJob) ───────────────────────────────

    def self.recover_stuck!
      threshold = Easyop.config.scheduler_stuck_threshold.to_i

      _model_class.where(state: 'running')
                  .where('locked_until < ?', Time.current - threshold)
                  .each do |task|
        if task.attempts >= task.max_attempts
          task.update_columns(state: 'dead')
          Easyop.config.scheduler_dead_letter_callback&.call(task)
        else
          task.update_columns(
            state:       'scheduled',
            run_at:      _compute_backoff(task),
            claimed_by:  nil,
            claimed_at:  nil
          )
        end
      end
    end

    def self.run_batch!
      batch_size  = Easyop.config.scheduler_batch_size
      lock_window = Easyop.config.scheduler_lock_window.to_i
      worker_id   = "#{Socket.gethostname}:#{Process.pid}:#{Thread.current.object_id}"

      tasks = _model_class.claim_due_batch(
        batch_size: batch_size,
        lock_window: lock_window,
        worker_id:   worker_id
      )

      tasks.each { |task| _execute_task!(task) }
    end

    # Test helper — runs the batch inline without enqueuing a job.
    def self.tick_now!
      recover_stuck!
      run_batch!
    end

    # ── Private helpers ──────────────────────────────────────────────────────

    def self._model_class
      Easyop.config.scheduler_model.constantize
    end
    private_class_method :_model_class

    def self._adapter_name
      _model_class.connection.adapter_name.downcase
    rescue
      'unknown'
    end
    private_class_method :_adapter_name

    def self._create_task(attrs)
      if attrs[:dedup_key]
        _model_class.find_or_create_by(dedup_key: attrs[:dedup_key]) do |task|
          task.assign_attributes(attrs)
        end
      else
        _model_class.create!(attrs.reject { |k, _| k == :dedup_key })
      end
    end
    private_class_method :_create_task

    def self._execute_task!(task)
      op_class = task.operation_class.safe_constantize
      unless op_class
        task.update_columns(state: 'dead', last_error_class: 'NameError',
                            last_error_message: "#{task.operation_class} is not defined")
        Easyop.config.scheduler_dead_letter_callback&.call(task)
        return
      end

      attrs = Serializer.deserialize(task.ctx_data)
      ctx   = Easyop::Ctx.build(attrs)
      op_class.new._easyop_run(ctx, raise_on_failure: false)

      task.update_columns(state: 'completed')
      _schedule_next_recurring!(task) if task.respond_to?(:cron) && task.cron.present?
    rescue StandardError => e
      task.increment!(:attempts)
      if task.attempts >= task.max_attempts
        task.update_columns(state: 'dead', last_error_class: e.class.name,
                            last_error_message: e.message.to_s[0, 500])
        Easyop.config.scheduler_dead_letter_callback&.call(task)
      else
        task.update_columns(
          state:              'scheduled',
          run_at:             _compute_backoff(task),
          last_error_class:   e.class.name,
          last_error_message: e.message.to_s[0, 500]
        )
      end
    end
    private_class_method :_execute_task!

    def self._schedule_next_recurring!(task)
      next_time = _next_cron_time(task.cron)
      return unless next_time

      _model_class.create!(
        operation_class: task.operation_class,
        ctx_data:        task.ctx_data,
        run_at:          next_time,
        cron:            task.cron,
        parent_id:       task.parent_id || task.id,
        max_attempts:    task.max_attempts,
        tags:            task.tags,
        state:           'scheduled'
      )
    end
    private_class_method :_schedule_next_recurring!

    def self._next_cron_time(expression)
      return nil unless defined?(Fugit)

      cron = Fugit.parse(expression)
      return nil unless cron.respond_to?(:next_time)

      cron.next_time.to_t
    rescue
      nil
    end
    private_class_method :_next_cron_time

    def self._compute_backoff(task)
      backoff = Easyop.config.scheduler_default_backoff
      attempts = task.attempts

      seconds = case backoff
                when :linear
                  attempts * 30
                when :exponential
                  [(2**attempts) * 60, 3600].min
                when Proc
                  backoff.call(attempts, task).to_i
                else
                  60
                end

      Time.current + seconds
    end
    private_class_method :_compute_backoff
  end
end
