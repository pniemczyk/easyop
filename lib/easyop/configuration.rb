module Easyop
  class Configuration
    # Which type adapter to use for Schema validation.
    # Options: :none, :native, :literal, :dry, :active_model
    attr_accessor :type_adapter

    # When true, type mismatches in schemas raise Ctx::Failure.
    # When false (default), mismatches emit a warning and execution continues.
    attr_accessor :strict_types

    def initialize
      @type_adapter = :native
      @strict_types = false
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
