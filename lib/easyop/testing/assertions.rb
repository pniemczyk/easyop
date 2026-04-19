# frozen_string_literal: true

module Easyop
  module Testing
    # Core helpers for asserting on Easyop::Ctx results.
    # These methods integrate with Minitest assert methods when available,
    # and raise plain RuntimeError otherwise (for RSpec / plain Ruby).
    module Assertions
      # ── Callers ───────────────────────────────────────────────────────────

      # Call an operation; always returns ctx, never raises on failure.
      def op_call(klass, **attrs)
        klass.call(attrs)
      end

      # Call an operation with call!; raises Easyop::Ctx::Failure on failure.
      def op_call!(klass, **attrs)
        klass.call!(attrs)
      end

      # ── Result assertions ─────────────────────────────────────────────────

      # Assert the operation succeeded.
      #   assert_op_success ctx
      def assert_op_success(ctx, msg = nil)
        message = msg || begin
          base = "Expected operation to succeed"
          ctx.failure? ? "#{base} but it failed#{ctx.error ? ": #{ctx.error.inspect}" : ""}" : base
        end
        _easyop_assert ctx.success?, message
      end

      # Assert the operation failed, optionally matching the error message.
      #   assert_op_failure ctx
      #   assert_op_failure ctx, error: "Insufficient credits"
      #   assert_op_failure ctx, error: /insufficient/i
      def assert_op_failure(ctx, error: nil, msg: nil)
        _easyop_assert ctx.failure?,
          msg || "Expected operation to fail but it succeeded"
        return unless error

        actual = ctx.error.to_s
        if error.is_a?(Regexp)
          _easyop_assert error.match?(actual),
            "Expected error #{actual.inspect} to match #{error.inspect}"
        else
          _easyop_assert_equal error.to_s, actual,
            "Expected error #{actual.inspect} to equal #{error.inspect}"
        end
      end

      # Assert specific key-value pairs exist in ctx.
      #   assert_ctx_has ctx, user_id: 42, plan: "pro"
      def assert_ctx_has(ctx, **expected)
        expected.each do |key, value|
          actual = ctx[key]
          _easyop_assert_equal value, actual,
            "Expected ctx[#{key.inspect}] = #{value.inspect}, got #{actual.inspect}"
        end
      end

      # ── Operation stubbing ────────────────────────────────────────────────

      # Stub an operation to return a preset ctx without executing it.
      # Requires Minitest::Mock or a compatible stub mechanism.
      #
      #   stub_op(Users::Register, success: false, error: "Already exists") do
      #     # code under test that calls Users::Register.call(...)
      #     ...
      #   end
      def stub_op(klass, success: true, error: nil, **ctx_attrs, &block)
        stubbed = Easyop::Ctx.new(**ctx_attrs)
        unless success
          begin
            stubbed.fail!(error: error || "Stubbed failure")
          rescue Easyop::Ctx::Failure
            # mark failed without propagating
          end
        end

        raise_failure = ->(*_) { raise Easyop::Ctx::Failure, stubbed }

        klass.stub(:call,  stubbed) do
          klass.stub(:call!, success ? stubbed : raise_failure) do
            block.call if block
          end
        end
      end

      private

      def _easyop_assert(condition, message)
        if respond_to?(:assert, true)
          assert condition, message
        else
          raise message unless condition
        end
      end

      def _easyop_assert_equal(expected, actual, message)
        if respond_to?(:assert_equal, true)
          assert_equal expected, actual, message
        else
          raise message unless expected == actual
        end
      end
    end
  end
end
