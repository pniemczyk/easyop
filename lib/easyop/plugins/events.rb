# frozen_string_literal: true

module Easyop
  module Plugins
    # Emits domain events after an operation completes.
    #
    # Install on a base operation class to inherit into all subclasses:
    #
    #   class ApplicationOperation
    #     include Easyop::Operation
    #     plugin Easyop::Plugins::Events
    #   end
    #
    # Then declare events on individual operations:
    #
    #   class PlaceOrder < ApplicationOperation
    #     emits "order.placed", on: :success, payload: [:order_id, :total]
    #     emits "order.failed", on: :failure, payload: ->(ctx) { { error: ctx.error } }
    #     emits "order.attempted", on: :always
    #
    #     def call
    #       ctx.order_id = Order.create!(ctx.to_h).id
    #     end
    #   end
    #
    # Plugin options:
    #   bus:      [Bus::Base, nil]  per-class bus override (default: global registry bus)
    #   metadata: [Hash, Proc, nil] extra metadata merged into every event from this class
    #
    # `emits` DSL options:
    #   on:      [:success (default), :failure, :always]
    #   payload: [Proc, Array, nil]  Proc receives ctx; Array slices ctx keys; nil = full ctx.to_h
    #   guard:   [Proc, nil]         extra condition — event only fires if truthy
    module Events
      def self.install(base, bus: nil, metadata: nil, **_options)
        base.extend(ClassMethods)
        base.prepend(RunWrapper)
        base.instance_variable_set(:@_events_bus,      bus)
        base.instance_variable_set(:@_events_metadata, metadata)
      end

      module ClassMethods
        # Declare an event this operation emits after execution.
        #
        # @example
        #   emits "order.placed", on: :success, payload: [:order_id]
        #   emits "order.failed", on: :failure, payload: ->(ctx) { { error: ctx.error } }
        #
        # @param name   [String]
        # @param on     [Symbol]        :success (default), :failure, or :always
        # @param payload [Proc, Array, nil]
        # @param guard  [Proc, nil]     optional condition — fires only when truthy
        def emits(name, on: :success, payload: nil, guard: nil)
          _emitted_events << { name: name.to_s, on: on, payload: payload, guard: guard }
        end

        # @api private — inheritable list of emits declarations
        def _emitted_events
          @_emitted_events ||= _inherited_emitted_events
        end

        # @api private — bus for this class (falls back to superclass, then global registry)
        def _events_bus
          if instance_variable_defined?(:@_events_bus)
            @_events_bus
          elsif superclass.respond_to?(:_events_bus)
            superclass._events_bus
          end
        end

        # @api private — metadata for this class (falls back to superclass)
        def _events_metadata
          if instance_variable_defined?(:@_events_metadata)
            @_events_metadata
          elsif superclass.respond_to?(:_events_metadata)
            superclass._events_metadata
          end
        end

        private

        def _inherited_emitted_events
          superclass.respond_to?(:_emitted_events) ? superclass._emitted_events.dup : []
        end
      end

      module RunWrapper
        # Wraps _easyop_run to publish declared events in an ensure block.
        # Events fire AFTER the operation completes — success, failure, or exception.
        def _easyop_run(ctx, raise_on_failure:)
          super
        ensure
          _events_publish_all(ctx)
        end

        private

        def _events_publish_all(ctx)
          declarations = self.class._emitted_events
          return if declarations.empty?

          bus = self.class._events_bus || Easyop::Events::Registry.bus

          declarations.each do |decl|
            next unless _events_should_fire?(decl, ctx)

            event = _events_build_event(decl, ctx)
            bus.publish(event)
          rescue StandardError
            # Individual publish failures must never crash the operation.
            # Log if Rails is available.
            _events_log_warning($ERROR_INFO)
          end
        end

        def _events_should_fire?(decl, ctx)
          case decl[:on]
          when :success then return false unless ctx.success?
          when :failure then return false unless ctx.failure?
          when :always  then nil # always fire
          end

          guard = decl[:guard]
          guard ? guard.call(ctx) : true
        end

        def _events_build_event(decl, ctx)
          Easyop::Events::Event.new(
            name:      decl[:name],
            payload:   _events_extract_payload(decl[:payload], ctx),
            metadata:  _events_build_metadata(ctx),
            source:    self.class.name
          )
        end

        def _events_extract_payload(payload_spec, ctx)
          case payload_spec
          when Proc  then payload_spec.call(ctx)
          when Array then ctx.slice(*payload_spec)
          when nil   then ctx.to_h
          else payload_spec
          end
        end

        def _events_build_metadata(ctx)
          meta = self.class._events_metadata
          case meta
          when Proc then meta.call(ctx)
          when Hash then meta.dup
          else {}
          end
        end

        def _events_log_warning(err)
          return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

          Rails.logger.warn "[EasyOp::Events] Failed to publish event: #{err.message}"
        end
      end
    end
  end
end
