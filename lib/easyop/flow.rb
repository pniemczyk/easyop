# frozen_string_literal: true

require 'securerandom'

require_relative 'operation/step_builder'

module Easyop
  # Compose a sequence of operations that share a single ctx.
  #
  # Three execution modes, selected automatically:
  #
  #   Mode 1 — pure sync (no subject, no .async step): returns Ctx.
  #   Mode 2 — sync + fire-and-forget async (no subject, has .async step): returns Ctx;
  #             async steps are enqueued via klass.call_async (ActiveJob) and the flow
  #             continues immediately to the next step.
  #   Mode 3 — durable suspend-and-resume (subject declared): returns FlowRun;
  #             async steps are scheduled via the DB scheduler; the flow suspends until
  #             the scheduled time, then resumes at the next step.
  #
  # The subject macro is the ONLY durability trigger. An async step without subject is
  # fire-and-forget (Mode 2), not durable.
  #
  # Usage:
  #   # Mode 1
  #   class ProcessOrder
  #     include Easyop::Flow
  #     flow ValidateCart, ChargeCard, CreateOrder, NotifyUser
  #   end
  #   ctx = ProcessOrder.call(cart: cart)
  #
  #   # Mode 2
  #   class RegisterAndNotify
  #     include Easyop::Flow
  #     flow CreateUser, SendWelcomeEmail.async, AssignTrial
  #   end
  #   ctx = RegisterAndNotify.call(email: 'a@b.com')  # SendWelcomeEmail enqueued; flow continues
  #
  #   # Mode 3
  #   class OnboardSubscriber
  #     include Easyop::Flow
  #     subject :user
  #     flow CreateSubscription, SendWelcomeEmail.async, SendNudge.async(wait: 1.day), RecordComplete
  #   end
  #   flow_run = OnboardSubscriber.call(user: user, plan: :pro)
  #
  # Free composition: any flow can embed other flows (and plain operations) in its step list.
  # Durable (subject-bearing) sub-flows are flattened into the outer's resolved step list,
  # auto-promoting the outer to Mode 3. Async-only (Mode 2) sub-flows stay encapsulated and
  # their fire-and-forget semantics run locally.
  #
  # ## Recording plugin integration (flow tracing)
  #
  # When steps have the Recording plugin installed, `CallBehavior#call` forwards
  # the parent ctx keys so every step log entry shows the flow as its parent.
  module Flow
    # Raised when a flow declares subject but easyop/persistent_flow is not loaded.
    DurableSupportNotLoadedError = Class.new(StandardError)

    # Raised when a whole flow class is wrapped in .async (e.g. Inner.async(wait: 1.day)).
    # Deferred to v0.6. Use Easyop::Scheduler.schedule_at(Inner, ...) instead.
    AsyncFlowEmbeddingNotSupportedError = Class.new(ArgumentError)

    # Kept for one release for backward-compat rescue clauses. No longer raised by CallBehavior.
    AsyncStepRequiresPersistentFlowError = Class.new(ArgumentError)

    # Raised when a StepBuilder (skip_if, skip_unless, etc.) wraps a durable sub-flow.
    # Deferred to v0.6. Wrap the sub-flow in a plain operation instead.
    ConditionalDurableSubflowNotSupportedError = Class.new(ArgumentError)

    # Prepended so that Flow's `call` takes precedence over Operation's no-op
    # even though Operation is included inside Flow.included.
    module CallBehavior
      def call
        # ── Flow-tracing forwarding for the Recording plugin ──────────────────
        _flow_tracing = self.class.name &&
                        !self.class.respond_to?(:_recording_enabled?)
        if _flow_tracing
          ctx[:__recording_root_reference_id]     ||= SecureRandom.uuid
          _prev_parent_name                         = ctx[:__recording_parent_operation_name]
          _prev_parent_id                           = ctx[:__recording_parent_reference_id]
          ctx[:__recording_parent_operation_name]   = self.class.name
          ctx[:__recording_parent_reference_id]     = SecureRandom.uuid
        end

        pending_guard = nil

        self.class._resolved_flow_steps.each do |entry|
          step, step_opts = if defined?(Easyop::Operation::StepBuilder) &&
                               entry.is_a?(Easyop::Operation::StepBuilder)
                               [entry.klass, entry.to_step_config]
                             else
                               [entry, {}]
                             end

          if step.is_a?(Proc)
            pending_guard = step
            next
          end

          # Guard: whole-flow embedded via .async — not yet supported.
          if step_opts[:async] && self.class._is_a_flow_class?(step)
            raise Easyop::Flow::AsyncFlowEmbeddingNotSupportedError,
                  "Marking an entire flow (#{step.name}) as async is not supported in v0.5. " \
                  "Use Easyop::Scheduler.schedule_at(#{step.name}, ...) instead."
          end

          # Mode 2: fire-and-forget for async steps in non-durable flows.
          # (In Mode 3 flows this path is never reached — the durable Runner drives steps.)
          if step_opts[:async]
            durable_only = step_opts.keys & %i[on_exception tags blocking]
            if durable_only.any?
              raise Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError,
                    "Options #{durable_only.inspect} are only valid inside a durable flow " \
                    "(declare `subject` to enable durable execution)."
            end

            if pending_guard
              skip = !pending_guard.call(ctx)
              pending_guard = nil
              next if skip
            end
            next if step_opts[:skip_if]&.call(ctx)
            next if step_opts[:skip_unless] && !step_opts[:skip_unless].call(ctx)
            async_opts = step_opts.slice(:wait, :wait_until, :queue, :at)
            async_opts[:wait]       = async_opts[:wait].call(ctx)       if async_opts[:wait].respond_to?(:call)
            async_opts[:wait_until] = async_opts[:wait_until].call(ctx) if async_opts[:wait_until].respond_to?(:call)
            step.call_async(ctx.to_h, **async_opts)
            next
          end

          # Evaluate lambda guard if present (placed before step in flow list)
          if pending_guard
            skip = !pending_guard.call(ctx)
            pending_guard = nil
            next if skip
          end

          # StepBuilder skip_if / skip_unless guards
          if step_opts[:skip_if]&.call(ctx)
            next
          end
          if step_opts[:skip_unless] && !step_opts[:skip_unless].call(ctx)
            next
          end

          next if step.respond_to?(:skip?) && step.skip?(ctx)

          instance = step.new
          instance._easyop_run(ctx, raise_on_failure: true)
          ctx.called!(instance)
        end
      rescue Ctx::Failure
        ctx.rollback!
        raise
      ensure
        if _flow_tracing
          ctx[:__recording_parent_operation_name] = _prev_parent_name
          ctx[:__recording_parent_reference_id]   = _prev_parent_id
        end
      end
    end

    def self.included(base)
      base.include(Operation)
      base.extend(ClassMethods)
      base.prepend(CallBehavior)
    end

    module ClassMethods
      # Declare the polymorphic subject AR record that makes this flow durable (Mode 3).
      # Presence of subject is the ONLY durability trigger — async steps alone do not make
      # a flow durable.
      def subject(association_name)
        @_persistent_flow_subject = association_name.to_sym
      end

      def _persistent_flow_subject
        @_persistent_flow_subject
      end

      # Declare the ordered list of operation classes and optional lambda guards.
      #
      # Accepted forms:
      #   flow Step1, Step2, Step3                       # bare classes
      #   flow Step1, ->(ctx) { ctx.run? }, Step2, Step3 # lambda guard before a step
      def flow(*steps)
        @_flow_steps = steps
      end

      def _flow_steps
        @_flow_steps ||= []
      end

      # Whether this flow runs in durable mode (Mode 3).
      #
      # True when:
      # - subject is declared on this class, OR
      # - this class was included via Easyop::PersistentFlow (backward compat flag), OR
      # - any embedded sub-flow (recursively) has a subject.
      #
      # Async-step presence alone does NOT trigger durable mode.
      def _durable_flow?
        return @_durable_flow if defined?(@_durable_flow)
        @_durable_flow = @_persistent_flow_compat ||
                         !_persistent_flow_subject.nil? ||
                         _flow_steps.any? do |entry|
                           klass = entry.is_a?(Easyop::Operation::StepBuilder) ? entry.klass : entry
                           klass.is_a?(Class) && _is_a_flow_class?(klass) && klass._durable_flow?
                         end
      end

      # Resolved step list: same as _flow_steps for Mode-1/Mode-2 flows; for durable
      # (subject-bearing) sub-flows, those sub-flows' steps are spliced inline (macro
      # expansion). Mode-2 sub-flows stay encapsulated as single entries.
      def _resolved_flow_steps
        @_resolved_flow_steps ||= _flow_steps.flat_map do |entry|
          # A StepBuilder wrapping a durable sub-flow is not supported in v0.5.
          if defined?(Easyop::Operation::StepBuilder) &&
             entry.is_a?(Easyop::Operation::StepBuilder) &&
             _is_a_flow_class?(entry.klass) &&
             entry.klass._durable_flow?
            raise Easyop::Flow::ConditionalDurableSubflowNotSupportedError,
                  "Wrapping durable sub-flow #{entry.klass.name || entry.klass} with step " \
                  "modifiers (skip_if, skip_unless, async, etc.) is not supported in v0.5. " \
                  "Wrap it in an operation that calls #{entry.klass.name || entry.klass}.call(ctx.to_h) instead."
          elsif entry.is_a?(Class) && _is_a_flow_class?(entry) && entry._durable_flow?
            entry._resolved_flow_steps
          else
            [entry]
          end
        end
      end

      # The effective subject for this flow: own subject first, then first-found
      # from any embedded durable sub-flow (recursively, depth-first).
      def _resolved_subject
        return _persistent_flow_subject if _persistent_flow_subject

        _flow_steps.each do |entry|
          next unless entry.is_a?(Class) && _is_a_flow_class?(entry) && entry._durable_flow?
          found = entry._resolved_subject
          return found if found
        end
        nil
      end

      def _is_a_flow_class?(klass)
        klass.is_a?(Class) && klass.ancestors.include?(Easyop::Flow)
      end

      # Start a durable flow run (Mode 3). Creates a FlowRun row and begins execution.
      # Requires easyop/persistent_flow to be loaded; raises DurableSupportNotLoadedError otherwise.
      #
      # @return [EasyFlowRun] the created flow run record
      def _start_durable!(attrs = {})
        unless defined?(Easyop::PersistentFlow::Runner)
          raise Easyop::Flow::DurableSupportNotLoadedError,
                "#{name} is a durable flow (subject declared) but easyop/persistent_flow " \
                "is not loaded. Add `require \"easyop/persistent_flow\"` to your initializer."
        end

        flow_run_class = Easyop.config.persistent_flow_model.constantize

        flow_run_attrs = {
          flow_class:         name,
          context_data:       Easyop::Scheduler::Serializer.serialize(attrs),
          status:             'pending',
          current_step_index: 0
        }

        if (subj_key = _resolved_subject)
          subj = attrs[subj_key] || attrs[subj_key.to_s]
          if subj && defined?(ActiveRecord::Base) && subj.is_a?(ActiveRecord::Base)
            flow_run_attrs[:subject_type] = subj.class.name
            flow_run_attrs[:subject_id]   = subj.id
          end
        end

        flow_run = flow_run_class.create!(flow_run_attrs)
        Easyop::PersistentFlow::Runner.advance!(flow_run)
        flow_run
      end

      # .call dispatch: durable flows return FlowRun; sync flows (Mode 1 & 2) return Ctx.
      def call(attrs = {})
        return _start_durable!(attrs) if _durable_flow?
        super
      end

      # .call! dispatch: same as .call for durable flows (both return FlowRun).
      def call!(attrs = {})
        return _start_durable!(attrs) if _durable_flow?
        super
      end

      # Deprecated alias for .call — kept for backward compatibility with PersistentFlow.
      def start!(attrs = {})
        call(attrs)
      end

      # Returns a FlowBuilder for pre-registering callbacks before .call.
      #
      #   ProcessCheckout.prepare
      #     .on_success { |ctx| redirect_to order_path(ctx.order) }
      #     .on_failure { |ctx| flash[:error] = ctx.error }
      #     .call(user: current_user, cart: current_cart)
      def prepare
        if _durable_flow?
          raise ArgumentError,
                "#{name} is a durable flow. `prepare` is not supported for durable flows in v0.5."
        end
        FlowBuilder.new(self)
      end
    end
  end
end
