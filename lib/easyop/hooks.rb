module Easyop
  # Lightweight before/after/around hook system with no ActiveSupport dependency.
  #
  # Hook lists are inherited — a subclass starts with a copy of its parent's
  # hooks and may add its own without affecting the parent.
  #
  # Usage:
  #   before :method_name
  #   before { ctx.email = ctx.email.downcase }
  #   after  :send_notification
  #   around :with_logging
  #   around { |inner| Sentry.with_scope { inner.call } }
  #
  # Execution order:
  #   around hooks wrap everything (outermost first).
  #   Inside the around chain: before hooks → call → after hooks.
  #   after hooks run in an `ensure` block so they always execute.
  module Hooks
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Add a before hook (method name or block).
      def before(*methods, &block)
        methods.each { |m| _before_hooks << m }
        _before_hooks << block if block_given?
      end

      # Add an after hook (method name or block).
      def after(*methods, &block)
        methods.each { |m| _after_hooks << m }
        _after_hooks << block if block_given?
      end

      # Add an around hook (method name or block).
      # The hook must yield (or call its first argument) to continue the chain.
      def around(*methods, &block)
        methods.each { |m| _around_hooks << m }
        _around_hooks << block if block_given?
      end

      # Hook lists, inherited from superclass (returns a dup so additions
      # on a subclass don't pollute the parent).
      def _before_hooks
        @_before_hooks ||= _inherited_hooks(:_before_hooks)
      end

      def _after_hooks
        @_after_hooks ||= _inherited_hooks(:_after_hooks)
      end

      def _around_hooks
        @_around_hooks ||= _inherited_hooks(:_around_hooks)
      end

      private

      def _inherited_hooks(name)
        parent = superclass
        parent.respond_to?(name, true) ? parent.send(name).dup : []
      end
    end

    # Run the full hook chain around the user's `call` method.
    # around hooks wrap before+call+after; after hooks always run (ensure).
    def with_hooks(&block)
      inner = proc do
        run_hooks(self.class._before_hooks)
        begin
          block.call
        ensure
          run_hooks(self.class._after_hooks)
        end
      end

      call_through_around(self.class._around_hooks, inner)
    end

    private

    def run_hooks(hooks)
      hooks.each do |hook|
        case hook
        when Symbol then send(hook)
        when Proc   then instance_exec(&hook)
        end
      end
    end

    # Build a nested lambda chain so the first around hook is the outermost.
    def call_through_around(around_hooks, inner)
      chain = around_hooks.reverse.reduce(inner) do |acc, hook|
        proc do
          case hook
          when Symbol
            # Method must accept a block: def with_logging; yield; end
            send(hook) { acc.call }
          when Proc
            # Block receives a callable: around { |inner| ...; inner.call }
            instance_exec(acc, &hook)
          end
        end
      end
      chain.call
    end
  end
end
