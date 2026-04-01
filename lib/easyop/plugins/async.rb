# frozen_string_literal: true

module Easyop
  module Plugins
    # Enables async execution via ActiveJob.
    #
    # Usage:
    #   class Newsletter::SendBroadcast < ApplicationOperation
    #     plugin Easyop::Plugins::Async, queue: "broadcasts"
    #   end
    #
    #   # Enqueue immediately:
    #   Newsletter::SendBroadcast.call_async(subject: "Hello", body: "World")
    #
    #   # With scheduling options:
    #   Newsletter::SendBroadcast.call_async(attrs, wait: 10.minutes)
    #   Newsletter::SendBroadcast.call_async(attrs, wait_until: Date.tomorrow.noon)
    #   Newsletter::SendBroadcast.call_async(attrs, queue: "low_priority")
    #
    # ActiveRecord objects are serialized by (class, id) and re-fetched in the job.
    # Only serializable values (String, Integer, Float, Boolean, nil, Hash, Array,
    # or ActiveRecord::Base) should be passed.
    module Async
      def self.install(base, queue: "default", **_options)
        base.extend(ClassMethods)
        base.instance_variable_set(:@_async_default_queue, queue)
      end

      module ClassMethods
        # Enqueue the operation as a background job.
        #
        #   MyOp.call_async(email: "x@y.com")
        #   MyOp.call_async(email: "x@y.com", wait: 5.minutes, queue: "low")
        def call_async(attrs = {}, wait: nil, wait_until: nil, queue: nil, **extra_attrs)
          merged_attrs = attrs.merge(extra_attrs)
          _async_ensure_active_job!
          job = Easyop::Plugins::Async.job_class
          job = job.set(queue: queue || _async_default_queue)
          job = job.set(wait: wait)             if wait
          job = job.set(wait_until: wait_until) if wait_until
          job.perform_later(name, _async_serialize(merged_attrs))
        end

        def _async_default_queue
          @_async_default_queue ||
            (superclass.respond_to?(:_async_default_queue) ? superclass._async_default_queue : "default")
        end

        private

        def _async_ensure_active_job!
          return if defined?(ActiveJob::Base)
          raise LoadError, "ActiveJob is required for async operations."
        end

        # Serialize attrs for GlobalID / JSON storage.
        # AR objects → { "__ar_class" => "User", "__ar_id" => 42 }
        def _async_serialize(attrs)
          attrs.each_with_object({}) do |(k, v), h|
            h[k.to_s] = if defined?(ActiveRecord::Base) && v.is_a?(ActiveRecord::Base)
                           { "__ar_class" => v.class.name, "__ar_id" => v.id }
                         else
                           v
                         end
          end
        end
      end

      # The ActiveJob that deserializes and runs the operation.
      # Defined lazily so this file can be required before ActiveJob loads.
      def self.job_class
        @job_class ||= begin
          raise LoadError, "ActiveJob is required for Easyop::Plugins::Async" unless defined?(ActiveJob::Base)

          klass = Class.new(ActiveJob::Base) do
            queue_as :default

            def perform(operation_class, attrs)
              op_klass = operation_class.constantize
              deserialized = attrs.each_with_object({}) do |(k, v), h|
                h[k.to_sym] = if v.is_a?(Hash) && v["__ar_class"]
                                 v["__ar_class"].constantize.find(v["__ar_id"])
                               else
                                 v
                               end
              end
              op_klass.call(deserialized)
            end
          end

          # Give the anonymous class a constant name for serialization
          Easyop::Plugins::Async.const_set(:Job, klass) unless const_defined?(:Job)
          klass
        end
      end
    end
  end
end
