module Easyop
  module Plugins
    # Wraps the entire operation (including before/after hooks) in a database
    # transaction. On ctx.fail! or any unhandled exception the transaction rolls back.
    #
    # Supports ActiveRecord and Sequel out of the box.
    #
    # Usage — include style (classic):
    #   class TransferFunds
    #     include Easyop::Operation
    #     include Easyop::Plugins::Transactional
    #   end
    #
    # Usage — plugin DSL (recommended, works with ApplicationOperation):
    #   class ApplicationOperation
    #     include Easyop::Operation
    #     plugin Easyop::Plugins::Transactional
    #   end
    #
    # Or opt in per operation:
    #   class TransferFunds < ApplicationOperation
    #     plugin Easyop::Plugins::Transactional
    #   end
    #
    # To opt out when the parent has it:
    #   class ReadOnlyOp < ApplicationOperation
    #     transactional false
    #   end
    module Transactional
      # Support the `plugin` DSL: `plugin Easyop::Plugins::Transactional`
      def self.install(base, **_options)
        base.include(self)
      end

      def self.included(base)
        base.extend(ClassMethods)
        base.around(:_transactional_wrap)
      end

      module ClassMethods
        # Opt out of transaction wrapping: `transactional false`
        def transactional(enabled)
          @_transactional_enabled = enabled
        end

        def _transactional_enabled?
          return @_transactional_enabled if instance_variable_defined?(:@_transactional_enabled)
          superclass.respond_to?(:_transactional_enabled?) ? superclass._transactional_enabled? : true
        end
      end

      private

      def _transactional_wrap
        return yield unless self.class._transactional_enabled?

        db = if defined?(ActiveRecord::Base)
               ActiveRecord::Base
             elsif defined?(Sequel::Model)
               Sequel::Model.db
             else
               raise "Easyop::Plugins::Transactional requires ActiveRecord or Sequel"
             end

        db.transaction { yield }
      end
    end
  end
end
