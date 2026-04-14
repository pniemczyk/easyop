module Easyop
  class Configuration
    # Which type adapter to use for Schema validation.
    # Options: :none, :native, :literal, :dry, :active_model
    attr_accessor :type_adapter

    # When true, type mismatches in schemas raise Ctx::Failure.
    # When false (default), mismatches emit a warning and execution continues.
    attr_accessor :strict_types

    # Bus adapter for domain events (Easyop::Plugins::Events / EventHandlers).
    # Options: :memory (default), :active_support, or a bus adapter instance.
    #
    # @example
    #   Easyop.configure { |c| c.event_bus = :active_support }
    attr_accessor :event_bus

    def initialize
      @type_adapter = :native
      @strict_types = false
      @event_bus    = nil  # nil = Memory bus (see Easyop::Events::Registry)
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Reset config (useful in tests)
    def reset_config!
      @config = Configuration.new
    end
  end
end
