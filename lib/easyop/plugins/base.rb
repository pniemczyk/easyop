module Easyop
  module Plugins
    # Abstract base for EasyOp plugins.
    #
    # A plugin is any object responding to `.install(base_class, **options)`.
    # Inherit from Base for convenience and documentation:
    #
    #   module MyPlugin < Easyop::Plugins::Base
    #     def self.install(base, **options)
    #       base.prepend(RunWrapper)
    #       base.extend(ClassMethods)
    #     end
    #   end
    #
    # Plugins are activated via the `plugin` DSL on operation classes:
    #
    #   class ApplicationOperation
    #     include Easyop::Operation
    #     plugin MyPlugin, option: :value
    #   end
    class Base
      def self.install(_base, **_options)
        raise NotImplementedError, "#{name}.install(base, **options) must be implemented"
      end
    end
  end
end
