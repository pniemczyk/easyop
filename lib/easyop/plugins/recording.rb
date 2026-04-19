# frozen_string_literal: true

require 'securerandom'

module Easyop
  module Plugins
    # Records operation executions to a database model.
    #
    # Usage:
    #   class ApplicationOperation
    #     include Easyop::Operation
    #     plugin Easyop::Plugins::Recording, model: OperationLog
    #   end
    #
    # Required model columns (create with the generator migration):
    #   operation_name  :string,   null: false
    #   success         :boolean,  null: false
    #   error_message   :string
    #   params_data     :text               # stored as JSON
    #   duration_ms     :float
    #   performed_at    :datetime, null: false
    #
    # Optional flow-tracing columns:
    #   root_reference_id     :string   # shared across entire execution tree
    #   reference_id          :string   # unique to this operation execution
    #   parent_operation_name :string   # class name of the direct parent
    #   parent_reference_id   :string   # reference_id of the direct parent
    #
    # Optional result column:
    #   result_data           :text     # stored as JSON — selected ctx keys after call
    #
    # Optional execution order column:
    #   execution_index       :integer  # nil for root; 1-based within each parent
    #
    # Opt out per operation class:
    #   class MyOp < ApplicationOperation
    #     recording false
    #   end
    #
    # Options:
    #   model:         (required) ActiveRecord class
    #   record_params: true       pass false to skip params serialization; also accepts
    #                             Hash ({ attrs: :key }), Proc, or Symbol (method name)
    #   record_result: false      configure result capture at plugin level; also accepts
    #                             true (full ctx snapshot), Hash, Proc, or Symbol
    #   filter_keys:   []         additional keys/patterns to filter from params_data
    #                             (Symbol, String, or Regexp — additive with FILTERED_KEYS)
    #                             Filtered keys are kept in params_data but their value
    #                             is replaced with "[FILTERED]".
    #   encrypt_keys:  []         keys/patterns whose values are encrypted rather than
    #                             filtered. Requires Easyop.config.recording_secret (≥32 bytes).
    #                             Stored as { "$easyop_encrypted" => "<ciphertext>" } markers.
    #                             Decryptable via Easyop::SimpleCrypt.decrypt_marker(value).
    #                             (Symbol, String, or Regexp — additive with class-level DSL)
    #
    # Class-level DSL for encryption:
    #   encrypt_params :credit_card_number, /^card_/
    #
    # Precedence (highest wins):
    #   1. Built-in FILTERED_KEYS (password, token, etc.) → always "[FILTERED]"
    #   2. encrypt_keys / encrypt_params list → encrypted marker hash
    #   3. filter_keys / filter_params list  → "[FILTERED]"
    #   4. Otherwise → normal serialization (AR objects → {id:, class:})
    module Recording
      # Sensitive keys always filtered in params_data before persisting.
      # Their values are replaced with "[FILTERED]" rather than removed.
      FILTERED_KEYS = %i[password password_confirmation token secret api_key].freeze

      # Internal ctx keys used for flow tracing — excluded from params_data.
      INTERNAL_CTX_KEYS = %i[
        __recording_root_reference_id
        __recording_parent_operation_name
        __recording_parent_reference_id
        __recording_child_counts
      ].freeze

      def self.install(base, model:, record_params: true, record_result: false, filter_keys: [], encrypt_keys: [], **_options)
        base.extend(ClassMethods)
        base.prepend(RunWrapper)
        base.instance_variable_set(:@_recording_model,          model)
        base.instance_variable_set(:@_recording_record_params,  record_params)
        base.instance_variable_set(:@_recording_record_result,  record_result)
        base.instance_variable_set(:@_recording_filter_keys,    Array(filter_keys))
        base.instance_variable_set(:@_recording_encrypt_keys,   Array(encrypt_keys))
      end

      module ClassMethods
        # Disable recording for this class: `recording false`
        def recording(enabled)
          @_recording_enabled = enabled
        end

        def _recording_enabled?
          return @_recording_enabled if instance_variable_defined?(:@_recording_enabled)
          superclass.respond_to?(:_recording_enabled?) ? superclass._recording_enabled? : true
        end

        def _recording_model
          @_recording_model ||
            (superclass.respond_to?(:_recording_model) ? superclass._recording_model : nil)
        end

        # DSL for controlling params capture. Forms:
        #   record_params false           # disable params recording entirely
        #   record_params true            # explicit full ctx (default)
        #   record_params attrs: :key     # selective keys
        #   record_params { |ctx| {...} } # block
        #   record_params :build_params   # private method name
        def record_params(value = nil, attrs: nil, &block)
          @_recording_record_params = if block
            block
          elsif attrs
            { attrs: attrs }
          elsif !value.nil?
            value
          else
            true
          end
        end

        def _recording_record_params_config
          if instance_variable_defined?(:@_recording_record_params)
            @_recording_record_params
          elsif superclass.respond_to?(:_recording_record_params_config)
            superclass._recording_record_params_config
          else
            true
          end
        end

        # DSL for capturing result data after the operation runs. Forms:
        #   record_result true            # full ctx snapshot (FILTERED_KEYS applied)
        #   record_result attrs: :key     # one or more ctx keys
        #   record_result { |ctx| {...} } # block
        #   record_result :build_result   # private instance method name
        def record_result(value = nil, attrs: nil, &block)
          @_recording_record_result = if block
            block
          elsif attrs
            { attrs: attrs }
          elsif !value.nil?
            value
          else
            nil
          end
        end

        def _recording_record_result_config
          if instance_variable_defined?(:@_recording_record_result)
            @_recording_record_result
          elsif superclass.respond_to?(:_recording_record_result_config)
            superclass._recording_record_result_config
          else
            false
          end
        end

        # DSL to declare additional keys/patterns to filter in params_data.
        # Accepts Symbol, String, or Regexp. Additive with FILTERED_KEYS and
        # any filter_keys declared on parent classes or at the plugin install level.
        # Matched keys are kept in params_data but their value is replaced with "[FILTERED]".
        #
        # @example
        #   class ApplicationOperation < ...
        #     filter_params :api_token, /access.?key/i
        #   end
        def filter_params(*keys)
          @_recording_filter_keys = _own_recording_filter_keys + keys
        end

        # Returns the merged filter list: parent class keys + this class's own keys.
        # Does NOT include FILTERED_KEYS or the global config list — those are
        # merged at persist time so they stay hot-reloadable.
        def _recording_filter_keys
          parent = superclass.respond_to?(:_recording_filter_keys) ? superclass._recording_filter_keys : []
          parent + _own_recording_filter_keys
        end

        # DSL to declare keys whose values should be encrypted rather than redacted.
        # Accepts Symbol, String, or Regexp. Additive with any encrypt_keys declared
        # on parent classes or at the plugin install level.
        # Encrypted values are stored as { "$easyop_encrypted" => "<ciphertext>" }.
        # Requires Easyop.config.recording_secret to be set (≥32 bytes).
        # Decrypt with: Easyop::SimpleCrypt.decrypt_marker(value)
        #
        # @example
        #   class ChargePayment < ApplicationOperation
        #     encrypt_params :credit_card_number, /^card_/
        #   end
        def encrypt_params(*keys)
          @_recording_encrypt_keys = _own_recording_encrypt_keys + keys
        end

        # Returns the merged encrypt list: parent class keys + this class's own keys.
        def _recording_encrypt_keys
          parent = superclass.respond_to?(:_recording_encrypt_keys) ? superclass._recording_encrypt_keys : []
          parent + _own_recording_encrypt_keys
        end

        private

        def _own_recording_filter_keys
          instance_variable_defined?(:@_recording_filter_keys) ? @_recording_filter_keys : []
        end

        def _own_recording_encrypt_keys
          instance_variable_defined?(:@_recording_encrypt_keys) ? @_recording_encrypt_keys : []
        end
      end

      module RunWrapper
        def _easyop_run(ctx, raise_on_failure:)
          return super unless self.class._recording_enabled?
          return super unless (model = self.class._recording_model)
          return super unless self.class.name # skip anonymous classes

          # Snapshot the keys present in ctx RIGHT NOW — before any internal
          # tracing keys are written and before the operation body runs. This
          # lets _recording_safe_params emit only what was passed IN, not values
          # computed during the call (those belong in result_data).
          input_keys = ctx.to_h.keys

          # -- Flow tracing --
          # Each operation gets its own reference_id. The root_reference_id is
          # shared across the entire execution tree via ctx (set once, inherited).
          reference_id      = SecureRandom.uuid
          root_reference_id = ctx[:__recording_root_reference_id] ||= SecureRandom.uuid

          # Read current parent context — these become THIS operation's parent fields.
          parent_operation_name = ctx[:__recording_parent_operation_name]
          parent_reference_id   = ctx[:__recording_parent_reference_id]

          # Execution index: 1-based position among siblings (nil for root operations).
          # Counts are tracked per-parent in a hash stored in ctx so sibling chains
          # and nested sub-trees each maintain independent counters.
          execution_index = if parent_reference_id
            counts = ctx[:__recording_child_counts] ||= {}
            counts[parent_reference_id] = (counts[parent_reference_id] || 0) + 1
          end

          # Set THIS operation as the parent for any children that run inside super.
          # Save the previous values so we can restore them after (for siblings).
          prev_parent_name = parent_operation_name
          prev_parent_id   = parent_reference_id
          ctx[:__recording_parent_operation_name] = self.class.name
          ctx[:__recording_parent_reference_id]   = reference_id

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          super
        ensure
          # Always record — including when raise_on_failure: true raises Ctx::Failure
          # (e.g. when this operation is a step inside a Flow). Without the ensure
          # branch the tap block would be skipped and failures inside flows would
          # never be persisted.
          if start
            # Restore parent context so sibling steps see the correct parent.
            ctx[:__recording_parent_operation_name] = prev_parent_name
            ctx[:__recording_parent_reference_id]   = prev_parent_id

            ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
            _recording_persist!(ctx, model, ms,
              root_reference_id:     root_reference_id,
              reference_id:          reference_id,
              parent_operation_name: parent_operation_name,
              parent_reference_id:   parent_reference_id,
              execution_index:       execution_index,
              input_keys:            input_keys)
          end
        end

        private

        def _recording_persist!(ctx, model, duration_ms,
                                root_reference_id: nil, reference_id: nil,
                                parent_operation_name: nil, parent_reference_id: nil,
                                execution_index: nil, input_keys: nil)
          attrs = {
            operation_name:        self.class.name,
            success:               ctx.success?,
            error_message:         ctx.error,
            performed_at:          Time.current,
            duration_ms:           duration_ms,
            root_reference_id:     root_reference_id,
            reference_id:          reference_id,
            parent_operation_name: parent_operation_name,
            parent_reference_id:   parent_reference_id,
            execution_index:       execution_index
          }
          params_config = self.class._recording_record_params_config
          attrs[:params_data] = _recording_safe_params(ctx, params_config, input_keys) unless params_config == false
          attrs[:result_data] = _recording_safe_result(ctx) if self.class._recording_record_result_config

          # Only write columns the model actually has
          safe = attrs.select { |k, _| model.column_names.include?(k.to_s) }
          model.create!(safe)
        rescue => e
          _recording_warn(e)
        end

        def _recording_safe_params(ctx, config, input_keys = nil)
          raw = case config
                when true
                  # Restrict to keys that existed when the operation was invoked —
                  # values computed during the call body are excluded here and
                  # should be captured via record_result instead.
                  # INTERNAL_CTX_KEYS are stripped from input_keys because nested
                  # operations inherit parent tracing keys before their snapshot.
                  base = ctx.to_h.except(*INTERNAL_CTX_KEYS)
                  if input_keys
                    clean = input_keys - INTERNAL_CTX_KEYS
                    base.slice(*clean)
                  else
                    base
                  end
                when Hash
                  keys = Array(config[:attrs])
                  keys.each_with_object({}) { |k, h| h[k] = ctx[k] }
                when Proc
                  result = config.call(ctx)
                  return nil unless result.is_a?(Hash)
                  result
                when Symbol
                  result = send(config)
                  return nil unless result.is_a?(Hash)
                  result
                end
          _recording_apply_and_serialize(raw).to_json
        rescue
          nil
        end

        # Returns true when +key+ is in the extra filter list.
        # (Built-in FILTERED_KEYS check is handled by _recording_apply_and_serialize directly.)
        def _recording_filter_key?(key, extra_list)
          _recording_match_key?(key, extra_list)
        end

        def _recording_safe_result(ctx)
          config = self.class._recording_record_result_config
          return nil unless config

          raw = case config
                when true
                  ctx.to_h.except(*INTERNAL_CTX_KEYS)
                when Hash
                  keys = Array(config[:attrs])
                  keys.each_with_object({}) { |k, h| h[k] = ctx[k] }
                when Proc
                  result = config.call(ctx)
                  return nil unless result.is_a?(Hash)
                  result
                when Symbol
                  result = send(config)
                  return nil unless result.is_a?(Hash)
                  result
                end

          return nil unless raw.is_a?(Hash)
          _recording_apply_and_serialize(raw).to_json
        rescue
          nil
        end

        # Applies filter and encrypt lists to +hash+, then serializes values.
        #
        # Precedence:
        #   1. Built-in FILTERED_KEYS            → "[FILTERED]"   (always, cannot be overridden)
        #   2. encrypt_keys / encrypt_params list → encrypted marker hash
        #   3. filter_keys / filter_params list   → "[FILTERED]"
        #   4. Otherwise                          → normal serialization
        def _recording_apply_and_serialize(hash)
          filter_extra  = Easyop.config.recording_filter_keys.to_a + self.class._recording_filter_keys
          encrypt_extra = Easyop.config.recording_encrypt_keys.to_a + self.class._recording_encrypt_keys

          hash.each_with_object({}) do |(k, v), h|
            h[k] = if FILTERED_KEYS.include?(k.to_sym)
                     '[FILTERED]'
                   elsif _recording_match_key?(k, encrypt_extra)
                     _recording_encrypt_value(v)
                   elsif _recording_filter_key?(k, filter_extra)
                     '[FILTERED]'
                   else
                     _recording_serialize_value(v)
                   end
          end
        end

        # Encrypt a single value for storage. Serializes non-string values to JSON
        # first so structured data (hashes, AR stubs) can be recovered on decrypt.
        def _recording_encrypt_value(value)
          require 'easyop/simple_crypt'
          serialized = _recording_serialize_value(value)
          payload    = serialized.is_a?(String) ? serialized : serialized.to_json
          { Easyop::SimpleCrypt::MARKER_KEY => Easyop::SimpleCrypt.encrypt(payload) }
        rescue Easyop::SimpleCrypt::MissingSecretError, Easyop::SimpleCrypt::EncryptionError => e
          _recording_warn(e)
          '[ENCRYPTION_FAILED]'
        end

        # Returns true when +key+ matches any entry in +match_list+.
        def _recording_match_key?(key, match_list)
          match_list.any? do |pattern|
            case pattern
            when Regexp then pattern.match?(key.to_s)
            when Symbol then pattern == key.to_sym
            else             pattern.to_s == key.to_s
            end
          end
        end

        # Serializes a single value: AR objects become {id:, class:}, everything else passthrough.
        def _recording_serialize_value(v)
          v.is_a?(ActiveRecord::Base) ? { id: v.id, class: v.class.name } : v
        end

        def _recording_warn(err)
          return unless defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.warn "[EasyOp::Recording] Failed to record #{self.class.name}: #{err.message}"
        end
      end
    end
  end
end
