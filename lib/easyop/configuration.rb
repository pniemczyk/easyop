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

    # Extra keys to scrub from params_data across all recorded operations.
    # Appended to Recording::SCRUBBED_KEYS — never replaces the built-in list.
    # Accepts Symbol, String, or Regexp (matched against the stringified key name).
    #
    # @example
    #   Easyop.configure { |c| c.recording_scrub_keys = [:api_token, /token/i] }
    attr_accessor :recording_scrub_keys

    def initialize
      @type_adapter         = :native
      @strict_types         = false
      @event_bus            = nil  # nil = Memory bus (see Easyop::Events::Registry)
      @recording_scrub_keys = []
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
