module Easyop
  module Skip
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def skip_if(&block)
        @_skip_predicate = block
      end

      def _skip_predicate
        @_skip_predicate
      end

      # Returns true if this step should be skipped for the given ctx.
      def skip?(ctx)
        @_skip_predicate ? @_skip_predicate.call(ctx) : false
      end
    end
  end
end
