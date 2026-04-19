require "test_helper"

# Tests for the Recording plugin's encrypt_params and filter_params DSL.
# Uses anonymous ApplicationOperation subclasses to test in isolation.
class RecordingPluginTest < ActiveSupport::TestCase
  setup do
    OperationLog.delete_all
  end

  def make_op(&block)
    Class.new(ApplicationOperation, &block).tap do |klass|
      klass.define_method(:call) { ctx.result = "ok" }
    end
  end

  test "filter_params stores [FILTERED] for matched keys" do
    op = make_op do
      filter_params :secret_code
    end
    op.class_eval { def self.name = "Test::FilteredOp" }

    op.call(secret_code: "s3cr3t", amount: 100)

    log = OperationLog.order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    assert_equal "[FILTERED]", params["secret_code"],
      "filter_params key should be stored as [FILTERED]"
    assert_equal 100, params["amount"],
      "Non-filtered key should be stored as-is"
  end

  test "built-in FILTERED_KEYS always filters password" do
    op = make_op {}
    op.class_eval { def self.name = "Test::BuiltinFilterOp" }

    op.call(email: "user@example.com", password: "super_secret")

    log = OperationLog.order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    assert_equal "[FILTERED]", params["password"],
      "password is a built-in filtered key and must never be stored in plaintext"
    assert_equal "user@example.com", params["email"]
  end

  test "encrypt_params stores encrypted marker" do
    op = make_op do
      encrypt_params :credit_card_number
    end
    op.class_eval { def self.name = "Test::EncryptedOp" }

    op.call(credit_card_number: "4242424242424242", amount: 999)

    log = OperationLog.order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    card = params["credit_card_number"]
    assert card.is_a?(Hash), "Encrypted value should be a Hash"
    assert card.key?("$easyop_encrypted"), "Encrypted value should have $easyop_encrypted key"
    assert_not_nil card["$easyop_encrypted"],
      "Ciphertext should not be nil"
    assert_not_equal "4242424242424242", card["$easyop_encrypted"],
      "Plaintext card number must not appear in ciphertext"
  end

  test "encrypt_params round-trips: can decrypt back to original" do
    op = make_op do
      encrypt_params :credit_card_number
    end
    op.class_eval { def self.name = "Test::RoundTripOp" }

    op.call(credit_card_number: "4111111111111111")

    log = OperationLog.order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    decrypted = Easyop::SimpleCrypt.decrypt_marker(params["credit_card_number"])
    assert_equal "4111111111111111", decrypted,
      "Decrypted value should match the original plaintext"
  end

  test "encrypt_params wins over filter_params for same key" do
    op = make_op do
      encrypt_params :api_token
      filter_params  :api_token
    end
    op.class_eval { def self.name = "Test::EncryptWinsOp" }

    op.call(api_token: "my_token_value")

    log = OperationLog.order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    # Encrypt has higher precedence than filter (for non-built-in keys)
    token = params["api_token"]
    assert token.is_a?(Hash) && token.key?("$easyop_encrypted"),
      "encrypt_params should win over filter_params for the same key (non-built-in)"
  end

  test "built-in FILTERED_KEYS wins over encrypt_params" do
    op = make_op do
      encrypt_params :password
    end
    op.class_eval { def self.name = "Test::BuiltinWinsOp" }

    op.call(password: "secret123")

    log = OperationLog.order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    assert_equal "[FILTERED]", params["password"],
      "Built-in FILTERED_KEYS (password) must always win — encrypt cannot override the security baseline"
  end

  test "record_result attrs captures specific ctx keys" do
    op = make_op do
      record_result attrs: %i[result]
    end
    op.class_eval { def self.name = "Test::ResultOp" }

    op.call(input: "data")

    log = OperationLog.order(performed_at: :desc).first
    assert_not_nil log.result_data

    result = JSON.parse(log.result_data)
    assert_equal "ok", result["result"]
    assert_not result.key?("input"), "params are excluded from result_data"
  end

  test "recording false disables all recording for the class" do
    op = make_op do
      recording false
    end
    op.class_eval { def self.name = "Test::NoRecordingOp" }

    op.call(data: "something")

    assert_equal 0, OperationLog.count,
      "recording false should prevent any OperationLog from being created"
  end
end
