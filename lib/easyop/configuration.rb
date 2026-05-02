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

    # ── Scheduler (opt-in via require "easyop/scheduler") ────────────────────

    # AR model class name for the scheduled tasks table.
    attr_accessor :scheduler_model

    # Maximum tasks claimed and executed per tick.
    attr_accessor :scheduler_batch_size

    # How long a claimed row is considered "in flight" before the sweeper
    # resets it as stuck. Integer seconds or an ActiveSupport duration.
    attr_accessor :scheduler_lock_window

    # How long past locked_until before a running row is considered stuck.
    attr_accessor :scheduler_stuck_threshold

    # Default max retry attempts per scheduled task.
    attr_accessor :scheduler_default_max_attempts

    # Default backoff strategy between retry attempts.
    # :linear     → attempts * 30 seconds
    # :exponential → (2 ** attempts).minutes (capped at 1 hour)
    # Proc        → ->(attempts, task) { <seconds> }
    attr_accessor :scheduler_default_backoff

    # Called when a task exhausts its retries and transitions to state='dead'.
    # Proc or nil.
    attr_accessor :scheduler_dead_letter_callback

    # ── PersistentFlow (opt-in via require "easyop/persistent_flow") ─────────

    # AR model class name for the flow runs table.
    attr_accessor :persistent_flow_model

    # AR model class name for the flow run steps table.
    attr_accessor :persistent_flow_step_model

    def initialize
      @type_adapter           = :native
      @strict_types           = false
      @event_bus              = nil  # nil = Memory bus (see Easyop::Events::Registry)
      @recording_filter_keys  = []
      @recording_encrypt_keys = []
      @recording_secret       = nil

      @scheduler_model                = 'EasyScheduledTask'
      @scheduler_batch_size           = 50
      @scheduler_lock_window          = 300   # 5 minutes in seconds
      @scheduler_stuck_threshold      = 600   # 10 minutes in seconds
      @scheduler_default_max_attempts = 3
      @scheduler_default_backoff      = :exponential
      @scheduler_dead_letter_callback = nil

      @persistent_flow_model      = 'EasyFlowRun'
      @persistent_flow_step_model = 'EasyFlowRunStep'
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
