module Easyop
  # Lightweight rescue_from DSL, modelled after ActiveSupport::Rescuable.
  # Works without ActiveSupport and can be used standalone.
  #
  # Usage:
  #   rescue_from SomeError, with: :handle_it
  #   rescue_from OtherError, AnotherError do |e|
  #     ctx.fail!(error: e.message)
  #   end
  #
  # Handlers are checked in definition order (first match wins).
  # Subclasses inherit their parent's handlers.
  module Rescuable
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Register a handler for one or more exception classes.
      # Pass `with: :method_name` or a block.
      def rescue_from(*klasses, with: nil, &block)
        raise ArgumentError, "Provide `with:` or a block" unless with || block_given?

        handler = with || block
        klasses.each do |klass|
          _rescue_handlers << [klass, handler]
        end
      end

      # Own handlers defined directly on this class (not inherited).
      def _rescue_handlers
        @_rescue_handlers ||= []
      end

      # Full ordered list: own handlers first, then ancestors' (child wins).
      def _all_rescue_handlers
        parent = superclass
        parent_handlers = parent.respond_to?(:_all_rescue_handlers) ? parent._all_rescue_handlers : []
        _rescue_handlers + parent_handlers
      end
    end

    # Attempt to handle `exception` with a registered handler.
    # Returns true if handled, false if no matching handler found.
    def rescue_with_handler(exception)
      handler = handler_for_rescue(exception)
      return false unless handler

      case handler
      when Symbol then send(handler, exception)
      when Proc   then instance_exec(exception, &handler)
      end
      true
    end

    private

    def handler_for_rescue(exception)
      self.class._all_rescue_handlers.each do |klass, handler|
        klass_const = klass.is_a?(String) ? Object.const_get(klass) : klass
        return handler if exception.is_a?(klass_const)
      rescue NameError
        next  # constant not loaded yet — skip
      end
      nil
    end
  end
end
