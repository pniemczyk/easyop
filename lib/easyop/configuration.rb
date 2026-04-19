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

    # Extra keys to filter from params_data across all recorded operations.
    # Appended to Recording::FILTERED_KEYS — never replaces the built-in list.
    # Matched keys are kept in params_data but their value is replaced with "[FILTERED]".
    # Accepts Symbol, String, or Regexp (matched against the stringified key name).
    #
    # @example
    #   Easyop.configure { |c| c.recording_filter_keys = [:api_token, /token/i] }
    attr_accessor :recording_filter_keys

    # Extra keys to encrypt in params_data / result_data using Easyop::SimpleCrypt.
    # Additive — merged with class-level encrypt_params DSL and plugin-install encrypt_keys:.
    # Matched values are stored as { "$easyop_encrypted" => ciphertext } markers.
    # Requires Easyop.config.recording_secret (or EASYOP_RECORDING_SECRET env) to be set.
    #
    # @example
    #   Easyop.configure { |c| c.recording_encrypt_keys = [:auth_token, /card/i] }
    attr_accessor :recording_encrypt_keys

    # Secret used by Easyop::SimpleCrypt when encrypting params_data / result_data values.
    # Must be ≥ 32 bytes. When not set here, SimpleCrypt walks the following chain:
    #
    #   1.  this attr  (highest priority)
    #   2.  ENV["EASYOP_RECORDING_SECRET"]
    #   3.  Rails.application.credentials.easyop.recording_secret   (nested namespace)
    #   4.  Rails.application.credentials.easyop_recording_secret   (flat key)
    #   5.  Rails.application.credentials.secret_key_base           (app fallback)
    #
    # @example Code config (explicit, highest priority)
    #   Easyop.configure { |c| c.recording_secret = ENV["MY_ENCRYPTION_KEY"] }
    #
    # @example Rails nested credentials (credentials.yml.enc)
    #   # easyop:
    #   #   recording_secret: <key>
    #   # Access: Rails.application.credentials.easyop.recording_secret
    #
    # @example Rails flat key (credentials.yml.enc)
    #   # easyop_recording_secret: <key>
    attr_accessor :recording_secret

    def initialize
      @type_adapter           = :native
      @strict_types           = false
      @event_bus              = nil  # nil = Memory bus (see Easyop::Events::Registry)
      @recording_filter_keys  = []
      @recording_encrypt_keys = []
      @recording_secret       = nil
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
