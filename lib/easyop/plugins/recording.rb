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
    # Opt out per operation class:
    #   class MyOp < ApplicationOperation
    #     recording false
    #   end
    #
    # Options:
    #   model:         (required) ActiveRecord class
    #   record_params: true       pass false to skip params serialization
    #   record_result: nil        configure result capture at plugin level (Hash/Proc/Symbol)
    module Recording
      # Sensitive keys scrubbed from params_data before persisting.
      SCRUBBED_KEYS = %i[password password_confirmation token secret api_key].freeze

      # Internal ctx keys used for flow tracing — excluded from params_data.
      INTERNAL_CTX_KEYS = %i[
        __recording_root_reference_id
        __recording_parent_operation_name
        __recording_parent_reference_id
      ].freeze

      def self.install(base, model:, record_params: true, record_result: nil, **_options)
        base.extend(ClassMethods)
        base.prepend(RunWrapper)
        base.instance_variable_set(:@_recording_model,         model)
        base.instance_variable_set(:@_recording_record_params,  record_params)
        base.instance_variable_set(:@_recording_record_result,  record_result)
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

        def _recording_record_params?
          if instance_variable_defined?(:@_recording_record_params)
            @_recording_record_params
          elsif superclass.respond_to?(:_recording_record_params?)
            superclass._recording_record_params?
          else
            true
          end
        end

        # DSL for capturing result data after the operation runs.
        # Three forms:
        #   record_result attrs: :key           # one or more ctx keys
        #   record_result { |ctx| { k: ctx.k } } # block
        #   record_result :build_result         # private instance method name
        def record_result(value = nil, attrs: nil, &block)
          @_recording_record_result = if block
            block
          elsif attrs
            { attrs: attrs }
          elsif value.is_a?(Symbol)
            value
          else
            value
          end
        end

        def _recording_record_result_config
          if instance_variable_defined?(:@_recording_record_result)
            @_recording_record_result
          elsif superclass.respond_to?(:_recording_record_result_config)
            superclass._recording_record_result_config
          else
            nil
          end
        end
      end

      module RunWrapper
        def _easyop_run(ctx, raise_on_failure:)
          return super unless self.class._recording_enabled?
          return super unless (model = self.class._recording_model)
          return super unless self.class.name # skip anonymous classes

          # -- Flow tracing --
          # Each operation gets its own reference_id. The root_reference_id is
          # shared across the entire execution tree via ctx (set once, inherited).
          reference_id      = SecureRandom.uuid
          root_reference_id = ctx[:__recording_root_reference_id] ||= SecureRandom.uuid

          # Read current parent context — these become THIS operation's parent fields.
          parent_operation_name = ctx[:__recording_parent_operation_name]
          parent_reference_id   = ctx[:__recording_parent_reference_id]

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
              parent_reference_id:   parent_reference_id)
          end
        end

        private

        def _recording_persist!(ctx, model, duration_ms,
                                root_reference_id: nil, reference_id: nil,
                                parent_operation_name: nil, parent_reference_id: nil)
          attrs = {
            operation_name:        self.class.name,
            success:               ctx.success?,
            error_message:         ctx.error,
            performed_at:          Time.current,
            duration_ms:           duration_ms,
            root_reference_id:     root_reference_id,
            reference_id:          reference_id,
            parent_operation_name: parent_operation_name,
            parent_reference_id:   parent_reference_id
          }
          attrs[:params_data] = _recording_safe_params(ctx) if self.class._recording_record_params?
          attrs[:result_data] = _recording_safe_result(ctx) if self.class._recording_record_result_config

          # Only write columns the model actually has
          safe = attrs.select { |k, _| model.column_names.include?(k.to_s) }
          model.create!(safe)
        rescue => e
          _recording_warn(e)
        end

        def _recording_safe_params(ctx)
          ctx.to_h
             .except(*SCRUBBED_KEYS, *INTERNAL_CTX_KEYS)
             .transform_values { |v| v.is_a?(ActiveRecord::Base) ? { id: v.id, class: v.class.name } : v }
             .to_json
        rescue
          nil
        end

        def _recording_safe_result(ctx)
          config = self.class._recording_record_result_config
          return nil unless config

          raw = case config
                when Hash
                  keys = Array(config[:attrs])
                  keys.each_with_object({}) { |k, h| h[k] = ctx[k] }
                when Proc
                  config.call(ctx)
                when Symbol
                  send(config)
                end

          return nil unless raw.is_a?(Hash)

          raw.transform_values { |v| v.is_a?(ActiveRecord::Base) ? { id: v.id, class: v.class.name } : v }
             .to_json
        rescue
          nil
        end

        def _recording_warn(err)
          return unless defined?(Rails) && Rails.respond_to?(:logger)
          Rails.logger.warn "[EasyOp::Recording] Failed to record #{self.class.name}: #{err.message}"
        end
      end
    end
  end
end
