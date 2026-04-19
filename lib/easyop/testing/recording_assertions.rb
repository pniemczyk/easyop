# frozen_string_literal: true

module Easyop
  module Testing
    # Assertions for Easyop::Plugins::Recording.
    # Use with Easyop::Testing::FakeModel as the recording model.
    #
    #   model = Easyop::Testing::FakeModel.new
    #   MyOp.call(email: "x@y.com", password: "secret")
    #   assert_params_filtered   model, :password
    #   assert_params_recorded   model, :email, "x@y.com"
    #   assert_recorded_success  model
    module RecordingAssertions
      # ── Record-level assertions ───────────────────────────────────────────

      # Assert the last record shows success: true.
      def assert_recorded_success(model, msg: nil)
        rec = _easyop_last_record!(model)
        _easyop_assert rec[:success] == true,
          msg || "Expected last record to be success but was failure" \
                 "#{rec[:error_message] ? ": #{rec[:error_message].inspect}" : ""}"
      end

      # Assert the last record shows success: false.
      # @param error [String, nil] optional exact match on error_message
      def assert_recorded_failure(model, error: nil, msg: nil)
        rec = _easyop_last_record!(model)
        _easyop_assert rec[:success] == false,
          msg || "Expected last record to be failure but was success"
        return unless error

        _easyop_assert_equal error, rec[:error_message],
          "Expected error_message #{rec[:error_message].inspect} to equal #{error.inspect}"
      end

      # ── params_data assertions ────────────────────────────────────────────

      # Assert params_data includes +key+, optionally matching +value+.
      #   assert_params_recorded model, :email               # key present
      #   assert_params_recorded model, :email, "x@y.com"   # key + value
      def assert_params_recorded(model, key, value = :__any__, msg: nil)
        params  = model.last_params
        str_key = key.to_s
        _easyop_assert params.key?(str_key),
          "Expected params_data to include #{key.inspect} but keys are: #{params.keys.inspect}"
        return if value == :__any__

        _easyop_assert_equal value, params[str_key],
          msg || "params_data[#{key.inspect}]: expected #{value.inspect}, got #{params[str_key].inspect}"
      end

      # Assert keys are stored as "[FILTERED]" in params_data.
      #   assert_params_filtered model, :password, :token
      def assert_params_filtered(model, *keys)
        params = model.last_params
        keys.each do |key|
          actual = params[key.to_s]
          _easyop_assert_equal "[FILTERED]", actual,
            "Expected params_data[#{key.inspect}] = \"[FILTERED]\" but was #{actual.inspect}"
        end
      end

      # Assert keys are stored as { "$easyop_encrypted" => "..." } in params_data.
      #   assert_params_encrypted model, :credit_card_number, :cvv
      def assert_params_encrypted(model, *keys)
        params = model.last_params
        keys.each do |key|
          actual = params[key.to_s]
          _easyop_assert(
            actual.is_a?(Hash) && actual.key?("$easyop_encrypted"),
            "Expected params_data[#{key.inspect}] to be an encrypted marker " \
            "({\"\\$easyop_encrypted\"=>\"...\"}) but was: #{actual.inspect}"
          )
        end
      end

      # Alias used in the roadmap spec.
      alias assert_ctx_encrypted assert_params_encrypted

      # Assert a key in params_data is NOT encrypted (and not filtered).
      def assert_params_not_encrypted(model, *keys)
        params = model.last_params
        keys.each do |key|
          actual = params[key.to_s]
          _easyop_assert(
            !(actual.is_a?(Hash) && actual.key?("$easyop_encrypted")),
            "Expected params_data[#{key.inspect}] to NOT be encrypted but it was"
          )
        end
      end

      # ── result_data assertions ────────────────────────────────────────────

      # Assert result_data includes +key+, optionally matching +value+.
      #   assert_result_recorded model, :user           # key present
      #   assert_result_recorded model, :status, "ok"  # key + value
      def assert_result_recorded(model, key, value = :__any__, msg: nil)
        result  = model.last_result
        str_key = key.to_s
        _easyop_assert result.key?(str_key),
          "Expected result_data to include #{key.inspect} but keys are: #{result.keys.inspect}"
        return if value == :__any__

        _easyop_assert_equal value, result[str_key],
          msg || "result_data[#{key.inspect}]: expected #{value.inspect}, got #{result[str_key].inspect}"
      end

      # Assert an AR-serialized object reference in params_data.
      # Recording serializes AR objects as { "class" => "ClassName", "id" => N }.
      #
      #   assert_ar_ref_in_params model, :user, class_name: "User"
      #   assert_ar_ref_in_params model, :user, class_name: "User", id: 42
      def assert_ar_ref_in_params(model, key, class_name:, id: nil)
        _assert_ar_ref model.last_params, key, class_name: class_name, id: id
      end

      # Assert an AR-serialized object reference in result_data.
      #   assert_ar_ref_in_result model, :article, class_name: "Article"
      def assert_ar_ref_in_result(model, key, class_name:, id: nil)
        _assert_ar_ref model.last_result, key, class_name: class_name, id: id
      end

      # ── Encryption helpers ────────────────────────────────────────────────

      # Decrypt an encrypted param from the spy and return the plaintext.
      # Requires Easyop.config.recording_secret (or EASYOP_RECORDING_SECRET env var).
      #
      #   card = decrypt_recorded_param(model, :credit_card_number)
      #   assert_equal "4242424242424242", card
      def decrypt_recorded_param(model, key)
        require "easyop/simple_crypt"
        Easyop::SimpleCrypt.decrypt_marker(model.last_params[key.to_s])
      end

      # Set recording_secret for the duration of a block, then restore.
      # Use when testing encrypt_params in isolation without a full Rails env.
      #
      #   with_recording_secret("a" * 32) do
      #     MyOp.call(card: "4242...")
      #     assert_params_encrypted model, :card
      #   end
      def with_recording_secret(secret = ("a" * 32), &block)
        original = Easyop.config.recording_secret
        Easyop.configure { |c| c.recording_secret = secret }
        block.call
      ensure
        Easyop.configure { |c| c.recording_secret = original }
      end

      private

      def _easyop_last_record!(model)
        rec = model.last
        _easyop_assert rec, "No records were written to the model spy"
        rec
      end

      def _assert_ar_ref(data, key, class_name:, id:)
        actual = data[key.to_s]
        _easyop_assert(
          actual.is_a?(Hash) && actual["class"] == class_name.to_s,
          "Expected #{key.inspect} to be an AR ref with class #{class_name.inspect}, got: #{actual.inspect}"
        )
        return unless id

        _easyop_assert_equal id, actual["id"],
          "Expected AR ref id = #{id.inspect}, got #{actual["id"].inspect}"
      end
    end
  end
end
