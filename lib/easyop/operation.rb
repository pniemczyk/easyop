module Easyop
  # The core module. Include this in any class to turn it into an operation.
  #
  # Usage:
  #   class DoSomething
  #     include Easyop::Operation
  #
  #     def call
  #       ctx.fail!(error: "nope") unless ctx.allowed
  #       ctx.result = do_work(ctx.input)
  #     end
  #   end
  #
  #   ctx = DoSomething.call(input: "data", allowed: true)
  #   ctx.success?  # => true
  #   ctx.result    # => ...
  module Operation
    def self.included(base)
      base.extend(ClassMethods)
      base.include(Hooks)
      base.include(Rescuable)
      base.include(Skip)
      base.include(Schema)
    end

    # ── Class-level API ───────────────────────────────────────────────────────

    module ClassMethods
      # Call the operation. Always returns ctx, never raises on ctx.fail!.
      # Other (unhandled) exceptions propagate normally.
      def call(attrs = {})
        new._easyop_run(Ctx.build(attrs), raise_on_failure: false)
      end

      # Call the operation. Returns ctx on success, raises Ctx::Failure on fail!.
      def call!(attrs = {})
        new._easyop_run(Ctx.build(attrs), raise_on_failure: true)
      end

      # Install a plugin onto this operation class.
      #
      #   plugin Easyop::Plugins::Instrumentation
      #   plugin Easyop::Plugins::Recording, model: OperationLog
      #   plugin Easyop::Plugins::Async, queue: "operations"
      #
      # The plugin must respond to `.install(base_class, **options)`.
      def plugin(plugin_mod, **options)
        plugin_mod.install(self, **options)
        _registered_plugins << { plugin: plugin_mod, options: options }
      end

      def _registered_plugins
        @_registered_plugins ||= []
      end

    end

    # ── Instance API ─────────────────────────────────────────────────────────

    # The shared context. Available inside `call`, hooks, and rescue handlers.
    def ctx
      @ctx
    end

    # Override this in subclasses.
    def call
      # no-op default
    end

    # Override to add rollback logic for use in Flow.
    def rollback
      # no-op default
    end

    # ── Internal ──────────────────────────────────────────────────────────────

    # @api private — called by ClassMethods.call / call!
    def _easyop_run(ctx, raise_on_failure:)
      @ctx = ctx
      if raise_on_failure
        _run_raising
      else
        _run_safe
      end
      ctx
    end

    private

    # run! — propagates Ctx::Failure to caller
    def _run_raising
      with_hooks { call }
    rescue Ctx::Failure
      raise
    rescue => e
      raise unless rescue_with_handler(e)
    end

    # run — swallows Ctx::Failure (ctx.failure? will be true)
    def _run_safe
      with_hooks { call }
    rescue Ctx::Failure
      # swallow — caller checks ctx.failure?
    rescue => e
      begin
        unless rescue_with_handler(e)
          # Unhandled exception: mark ctx failed and re-raise
          @ctx.fail!(error: e.message) rescue nil
          raise e
        end
      rescue Ctx::Failure
        # The rescue handler itself called ctx.fail! — swallow it
      end
    end
  end
end
