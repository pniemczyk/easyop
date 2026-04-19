require "test_helper"

class OperationLogTest < ActiveSupport::TestCase
  setup do
    OperationLog.delete_all
  end

  test "root? returns true when parent_reference_id is nil" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current
    )
    assert log.root?
  end

  test "root? returns false when parent_reference_id is present" do
    log = OperationLog.create!(
      operation_name: "TestStep",
      success: true,
      performed_at: Time.current,
      parent_reference_id: "some-uuid",
      reference_id: SecureRandom.uuid,
      root_reference_id: "root-uuid"
    )
    assert_not log.root?
  end

  test "parsed_params returns hash from JSON params_data" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current,
      params_data: '{"email":"test@example.com","amount":100}'
    )

    result = log.parsed_params
    assert_equal "test@example.com", result["email"]
    assert_equal 100, result["amount"]
  end

  test "parsed_params returns empty hash when params_data is nil" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current
    )
    assert_equal({}, log.parsed_params)
  end

  test "parsed_result returns hash from JSON result_data" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current,
      result_data: '{"user":{"id":1,"class":"User"}}'
    )

    result = log.parsed_result
    assert_equal "User", result["user"]["class"]
    assert_equal 1, result["user"]["id"]
  end

  test "has_encrypted_params? detects encrypted marker" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current,
      params_data: '{"credit_card_number":{"$easyop_encrypted":"abc123"},"amount":999}'
    )

    assert log.has_encrypted_params?
  end

  test "has_encrypted_params? returns false when no encrypted values" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current,
      params_data: '{"email":"test@example.com","password":"[FILTERED]"}'
    )

    assert_not log.has_encrypted_params?
  end

  test "encrypted_params_keys returns keys with encrypted markers" do
    log = OperationLog.create!(
      operation_name: "TestOp",
      success: true,
      performed_at: Time.current,
      params_data: '{"credit_card_number":{"$easyop_encrypted":"abc"},"cvv":{"$easyop_encrypted":"xyz"},"amount":999}'
    )

    keys = log.encrypted_params_keys
    assert_includes keys, "credit_card_number"
    assert_includes keys, "cvv"
    assert_not_includes keys, "amount"
  end

  test "successes scope returns only successful logs" do
    OperationLog.create!(operation_name: "Op1", success: true,  performed_at: Time.current)
    OperationLog.create!(operation_name: "Op2", success: false, performed_at: Time.current)

    assert_equal 1, OperationLog.successes.count
    assert_equal 1, OperationLog.failures.count
  end

  test "for_tree scope returns logs sharing root_reference_id" do
    tree_id = SecureRandom.uuid
    OperationLog.create!(operation_name: "Root", success: true, performed_at: 2.seconds.ago,
                         root_reference_id: tree_id, reference_id: SecureRandom.uuid)
    OperationLog.create!(operation_name: "Step", success: true, performed_at: 1.second.ago,
                         root_reference_id: tree_id, reference_id: SecureRandom.uuid,
                         parent_reference_id: SecureRandom.uuid)
    OperationLog.create!(operation_name: "Other", success: true, performed_at: Time.current,
                         root_reference_id: SecureRandom.uuid, reference_id: SecureRandom.uuid)

    tree_logs = OperationLog.for_tree(tree_id)
    assert_equal 2, tree_logs.count
    assert_equal %w[Root Step], tree_logs.map(&:operation_name)
  end

  test "encrypted scope finds logs with encrypted params" do
    OperationLog.create!(operation_name: "Encrypted", success: true, performed_at: Time.current,
                         params_data: '{"card":{"$easyop_encrypted":"abc"}}')
    OperationLog.create!(operation_name: "Plain", success: true, performed_at: Time.current,
                         params_data: '{"email":"test@example.com"}')

    assert_equal 1, OperationLog.encrypted.count
    assert_equal "Encrypted", OperationLog.encrypted.first.operation_name
  end
end
