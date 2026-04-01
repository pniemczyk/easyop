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
