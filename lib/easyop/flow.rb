require 'securerandom'

module Easyop
  # Compose a sequence of operations that share a single ctx.
  #
  # If any step calls ctx.fail!, execution halts and rollback runs in reverse.
  # Each step can define a `rollback` method which will be called on failure.
  #
  # Usage:
  #   class ProcessOrder
  #     include Easyop::Flow
  #
  #     flow ValidateCart, ChargeCard, CreateOrder, NotifyUser
  #   end
  #
  # ## Recording plugin integration (flow tracing)
  #
  # When steps have the Recording plugin installed, `CallBehavior#call` forwards
  # the parent ctx keys so every step log entry shows the flow as its parent:
  #
  #   # Bare flow — flow itself is not recorded but steps see it as parent:
  #   class ProcessOrder
  #     include Easyop::Flow
  #     flow ValidateCart, ChargeCard
  #   end
  #
  # For full tree reconstruction (flow appears in operation_logs as the root
  # entry) inherit from your recorded base class and opt out of the transaction
  # so step-level transactions are not shadowed by an outer one:
  #
  #   class ProcessOrder < ApplicationOperation
  #     include Easyop::Flow
  #     transactional false   # EasyOp handles rollback; steps own their transactions
  #     flow ValidateCart, ChargeCard
  #   end
  #
  #   result = ProcessOrder.call(user: user, cart: cart)
  #   result.on_success { |ctx| redirect_to order_path(ctx.order) }
  #   result.on_failure { |ctx| flash[:alert] = ctx.error }
  #
  # Steps are run via `.call!` so a failure raises and stops the chain.
  # Individual steps can also be conditionally skipped:
  #
  #   flow ValidateCart,
  #        -> (ctx) { ctx.coupon_code? },  ApplyCoupon,   # conditional
  #        ChargeCard,
  #        CreateOrder
  #
  # A Lambda/Proc before a step is treated as a guard — the step only runs
  # if the lambda returns truthy when called with ctx.
  module Flow
    # Prepended so that Flow's `call` takes precedence over Operation's no-op
    # even though Operation is included inside Flow.included (which would
    # otherwise place Operation earlier in the ancestor chain than Flow itself).
    module CallBehavior
      def call
        # ── Flow-tracing forwarding for the Recording plugin ──────────────────
        # When Recording is NOT installed on this flow class (i.e. the flow does
        # not inherit from a base operation that has Recording), set the
        # __recording_parent_* ctx keys manually so every step operation knows
        # this flow is its parent.  When Recording IS installed on the flow (its
        # RunWrapper runs before `call` is reached), it has already set up the
        # parent context correctly — we detect that via _recording_enabled? and
        # skip to avoid a conflict.  If Recording is not used at all, these ctx
        # keys are unused and ignored.
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

        self.class._flow_steps.each do |step|
          if step.is_a?(Proc)
            pending_guard = step
            next
          end

          # Evaluate lambda guard if present (placed before step in flow list)
          if pending_guard
            skip = !pending_guard.call(ctx)
            pending_guard = nil
            next if skip
          end

          # Evaluate class-level skip_if predicate declared on the step itself
          next if step.respond_to?(:skip?) && step.skip?(ctx)

          instance = step.new
          instance._easyop_run(ctx, raise_on_failure: true)
          ctx.called!(instance)
        end
      rescue Ctx::Failure
        ctx.rollback!
        raise
      ensure
        # Restore parent context so any caller above this flow sees the right parent.
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
      # Declare the ordered list of operation classes (and optional guards).
      def flow(*steps)
        @_flow_steps = steps.flatten
      end

      def _flow_steps
        @_flow_steps ||= []
      end

      # Returns a FlowBuilder for pre-registering callbacks before .call.
      #
      #   ProcessCheckout.prepare
      #     .on_success { |ctx| redirect_to order_path(ctx.order) }
      #     .on_failure { |ctx| flash[:error] = ctx.error }
      #     .call(user: current_user, cart: current_cart)
      #
      #   ProcessCheckout.prepare
      #     .bind_with(self)
      #     .on(success: :order_placed, fail: :show_errors)
      #     .call(user: current_user, cart: current_cart)
      def prepare
        FlowBuilder.new(self)
      end
    end
  end
end
