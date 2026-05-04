# frozen_string_literal: true

module Easyop
  module Operation
    # Immutable, chainable builder for configuring an operation as a flow step
    # or as an async enqueue.
    #
    # Created via class-level entry points added by Easyop::Plugins::Async:
    #   Op.async(wait: 1.day)
    #   Op.async(wait: 1.day).skip_if { |ctx| ctx[:done] }
    #   Op.skip_unless { |ctx| ctx[:enabled] }.async(wait: 5.minutes)
    #
    # Two usage contexts:
    #
    # 1. Outside a flow — enqueue via call:
    #      Reports::GeneratePDF.async(wait: 5.minutes).call(report_id: 42)
    #      # equivalent to: Reports::GeneratePDF.call_async({ report_id: 42 }, wait: 5.minutes)
    #
    # 2. Inside a flow / PersistentFlow declaration — used as a step config:
    #      flow CreateUser,
    #           SendWelcomeEmail.async,
    #           SendNudge.async(wait: 1.day).skip_if { |ctx| !ctx[:newsletter] },
    #           RecordComplete
    #
    # ## Option accumulation rules
    #
    # - Scalar opts: last write wins. `.async(wait: 1.hour).wait(2.hours)` → `wait: 2.hours`.
    # - `:tags`: additive. `.async.tags(:a).tags(:b)` → `tags: [:a, :b]`.
    # - Call order does not matter: `.skip_if { ... }.async(wait: 1.day)` ==
    #   `.async(wait: 1.day).skip_if { ... }`.
    class StepBuilder
      PersistentFlowOnlyOptionsError = Class.new(ArgumentError)

      PERSISTENT_FLOW_ONLY_KEYS = %i[skip_if skip_unless on_exception tags blocking].freeze

      attr_reader :klass, :opts

      def initialize(klass, opts = {})
        @klass = klass
        @opts  = opts.freeze
      end

      # Mark step as async and set timing options.
      # wait:       ActiveSupport duration or seconds
      # wait_until: Time — schedule at an absolute time
      # queue:      queue name override
      def async(**new_opts)
        chain(async: true, **new_opts)
      end

      # Set wait duration without marking the step async.
      def wait(duration)
        chain(wait: duration)
      end

      # Skip this step when the block returns truthy.
      # Only valid inside a flow declaration.
      def skip_if(&block)
        chain(skip_if: block)
      end

      # Skip this step when the block returns falsy.
      # Only valid inside a flow declaration.
      def skip_unless(&block)
        chain(skip_unless: block)
      end

      # Set the exception policy for this step.
      # Only valid inside a PersistentFlow declaration.
      # policy: :cancel!, :reattempt!
      # opts:   max_reattempts:, wait:
      def on_exception(policy, **policy_opts)
        chain(on_exception: policy, **policy_opts)
      end

      # Add scheduler tags (additive — each call appends to the list).
      # Only valid inside a PersistentFlow declaration.
      def tags(*list)
        current = Array(@opts[:tags])
        chain(tags: current + list)
      end

      # Enqueue the operation as an async job.
      # Raises PersistentFlowOnlyOptionsError if persistent-flow-only opts are set.
      def call(attrs = {})
        _guard_persistent_flow_only_keys!
        async_opts = @opts.slice(:wait, :wait_until, :queue, :at)
        @klass.call_async(attrs, **async_opts)
      end

      # Extract accumulated options for consumption by the flow parser.
      def to_step_config
        @opts
      end

      private

      def chain(**new_opts)
        self.class.new(@klass, @opts.merge(new_opts))
      end

      def _guard_persistent_flow_only_keys!
        flow_only = @opts.keys & PERSISTENT_FLOW_ONLY_KEYS
        return if flow_only.empty?

        raise PersistentFlowOnlyOptionsError,
              "Options #{flow_only.inspect} are only valid inside a `flow` declaration. " \
              "They cannot be used when calling `.call(attrs)` directly."
      end
    end
  end
end
