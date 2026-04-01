module Easyop
  # FlowBuilder accumulates callbacks before executing a flow.
  # Returned by FlowClass.flow (no args) and FlowClass.result.
  #
  # Usage:
  #   ProcessCheckout.flow
  #     .on_success { |ctx| redirect_to order_path(ctx.order) }
  #     .on_failure { |ctx| flash[:error] = ctx.error; redirect_back }
  #     .call(user: current_user, cart: current_cart)
  #
  #   # With bound object (e.g. a Rails controller):
  #   ProcessCheckout.flow
  #     .bind_with(self)
  #     .on(success: :redirect_to_dashboard, fail: :render_form)
  #     .call(user: current_user, cart: current_cart)
  class FlowBuilder
    def initialize(flow_class)
      @flow_class        = flow_class
      @success_callbacks = []
      @failure_callbacks = []
      @bound_object      = nil
    end

    # Register a callback to run when the flow succeeds.
    def on_success(&block)
      @success_callbacks << block
      self
    end

    # Register a callback to run when the flow fails.
    def on_failure(&block)
      @failure_callbacks << block
      self
    end

    # Bind a context object for use with symbol shortcuts in `.on(...)`.
    # Typically `self` in a Rails controller.
    def bind_with(obj)
      @bound_object = obj
      self
    end

    # Register named-method callbacks. Requires bind_with to have been called
    # when the methods live on another object.
    #
    #   .on(success: :redirect_to_dashboard, fail: :render_form)
    def on(success: nil, fail: nil)
      bound = @bound_object
      if success
        success_name = success
        @success_callbacks << ->(ctx) { _invoke_named(bound, success_name, ctx) }
      end
      if fail
        fail_name = fail
        @failure_callbacks << ->(ctx) { _invoke_named(bound, fail_name, ctx) }
      end
      self
    end

    # Execute the flow with the given attributes, then fire the registered callbacks.
    # Returns the ctx (Easyop::Ctx).
    def call(attrs = {})
      ctx = @flow_class.call(attrs)
      callbacks = ctx.success? ? @success_callbacks : @failure_callbacks
      callbacks.each { |cb| cb.call(ctx) }
      ctx
    end

    private

    def _invoke_named(obj, name, ctx)
      if obj
        m = obj.method(name)
        m.arity == 0 ? m.call : m.call(ctx)
      else
        raise ArgumentError, "bind_with(obj) must be called before using symbol callbacks in .on()"
      end
    end
  end
end
