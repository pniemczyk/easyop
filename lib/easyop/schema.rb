module Easyop
  # Optional typed schema DSL for Operation inputs and outputs.
  #
  # When included (automatically when you use `params` or `result` in an
  # Operation), it adds before/after hooks that validate ctx against the
  # declared schema using the configured type adapter.
  #
  # Usage:
  #   params do
  #     required :email,    String
  #     required :amount,   Integer
  #     optional :note,     String
  #     optional :retry,    :boolean, default: false
  #   end
  #
  #   result do
  #     required :record, ActiveRecord::Base
  #     optional :token,  String
  #   end
  #
  # Type symbols (:boolean, :string, :integer, :float) are mapped to native
  # Ruby classes. Pass an actual class (String, User, etc.) for strict is_a?
  # checking. Type validation only happens if Easyop.config.type_adapter != :none.
  module Schema
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Declare input schema. Validated before `call` runs.
      def params(&block)
        schema = FieldSchema.new
        schema.instance_eval(&block)
        @_param_schema = schema

        # Register as a before hook (prepend so it runs first)
        _before_hooks.unshift(:_validate_params!)
      end
      alias inputs params

      # Declare output schema. Validated after `call` returns (not in ensure).
      def result(&block)
        schema = FieldSchema.new
        schema.instance_eval(&block)
        @_result_schema = schema

        _after_hooks.push(:_validate_result!)
      end
      alias outputs result

      def _param_schema
        @_param_schema
      end

      def _result_schema
        @_result_schema
      end
    end

    # ── Instance validation methods ───────────────────────────────────────────

    def _validate_params!
      schema = self.class._param_schema
      return unless schema
      schema.validate!(ctx, phase: :params)
    end

    def _validate_result!
      schema = self.class._result_schema
      return unless schema && ctx.success?
      schema.validate!(ctx, phase: :result)
    end
  end

  # Describes a set of typed fields (used for both params and result schemas).
  class FieldSchema
    TYPE_MAP = {
      string:  String,
      integer: Integer,
      float:   Float,
      boolean: [TrueClass, FalseClass],
      symbol:  Symbol,
      any:     BasicObject,
    }.freeze

    Field = Struct.new(:name, :type, :required, :default, :has_default, keyword_init: true)

    def initialize
      @fields = []
    end

    def required(name, type = nil, **opts)
      add_field(name, type, required: true, **opts)
    end

    def optional(name, type = nil, **opts)
      add_field(name, type, required: false, **opts)
    end

    def fields
      @fields.dup
    end

    # Validate ctx against this schema.
    # Raises Ctx::Failure on hard errors; emits warnings otherwise
    # depending on Easyop.config.strict_types.
    def validate!(ctx, phase: :params)
      @fields.each do |field|
        val = ctx[field.name]

        # Apply default if not set
        if val.nil? && field.has_default
          ctx[field.name] = field.default.respond_to?(:call) ? field.default.call : field.default
          val = ctx[field.name]
        end

        # Required check
        if field.required && val.nil?
          ctx.fail!(
            error:  "Missing required #{phase} field: #{field.name}",
            errors: ctx.errors.merge(field.name => "is required")
          )
        end

        # Type check (skip if nil and optional)
        next if val.nil?
        next if field.type.nil?

        type_check!(ctx, field, val, phase)
      end
    end

    private

    def add_field(name, type, required:, default: :__no_default__, **_rest)
      resolved = resolve_type(type)
      @fields << Field.new(
        name:        name.to_sym,
        type:        resolved,
        required:    required,
        default:     default == :__no_default__ ? nil : default,
        has_default: default != :__no_default__
      )
    end

    def resolve_type(type)
      return nil if type.nil?
      return type if type.is_a?(Class) || type.is_a?(Array)

      TYPE_MAP[type.to_sym] || (raise ArgumentError, "Unknown type shorthand: #{type.inspect}")
    end

    def type_check!(ctx, field, val, phase)
      types = Array(field.type)
      valid = types.any? { |t| t == BasicObject || val.is_a?(t) }
      return if valid

      msg = "Type mismatch in #{phase} field :#{field.name} — " \
            "expected #{types.map(&:name).join(" | ")}, got #{val.class}"

      if Easyop.config.strict_types
        ctx.fail!(error: msg, errors: ctx.errors.merge(field.name => msg))
      else
        warn "[Easyop] #{msg}"
      end
    end
  end
end
