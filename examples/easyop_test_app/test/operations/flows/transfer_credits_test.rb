require "test_helper"

class Flows::TransferCreditsTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)  # 500 credits
    @bob   = users(:bob)    # 200 credits
    @dave  = users(:dave)   # 0 credits
    OperationLog.delete_all
  end

  test "transfers credits between users" do
    result = Flows::TransferCredits.call(
      sender:    @alice,
      recipient: @bob,
      amount:    100
    )

    assert result.success?, "Expected success but got: #{result[:error]}"
    assert_equal 400, @alice.reload.credits
    assert_equal 300, @bob.reload.credits
  end

  test "records multiple operation logs (one per step)" do
    Flows::TransferCredits.call(
      sender:    @alice,
      recipient: @bob,
      amount:    50
    )

    logs = OperationLog.all.to_a
    op_names = logs.map(&:operation_name)

    # The flow and its steps should all be recorded
    assert op_names.include?("Flows::TransferCredits"), "Flow root should be logged"
    assert op_names.include?("Flows::TransferCredits::DebitSender"), "DebitSender step should be logged"
    assert op_names.include?("Flows::TransferCredits::CreditRecipient"), "CreditRecipient step should be logged"
  end

  test "all logs share the same root_reference_id" do
    Flows::TransferCredits.call(
      sender:    @alice,
      recipient: @bob,
      amount:    50
    )

    root_ids = OperationLog.pluck(:root_reference_id).compact.uniq
    assert_equal 1, root_ids.size, "All logs in a flow tree should share one root_reference_id"
  end

  test "insufficient credits causes failure and rollback" do
    result = Flows::TransferCredits.call(
      sender:    @dave,   # 0 credits
      recipient: @bob,
      amount:    100
    )

    assert result.failure?
    assert_equal 0, @dave.reload.credits, "Sender credits should be unchanged after rollback"
    assert_equal 200, @bob.reload.credits, "Recipient credits should be unchanged after rollback"
  end

  test "applies optional 2% fee when apply_fee: true" do
    result = Flows::TransferCredits.call(
      sender:    @alice,
      recipient: @bob,
      amount:    100,
      apply_fee: true
    )

    assert result.success?
    # fee = ceil(100 * 0.02) = 2, amount after fee = 98
    assert_equal 400, @alice.reload.credits  # deducted full 100
    assert_equal 298, @bob.reload.credits    # received 98 (after fee)
    assert result.transfer_note.include?("fee")
  end

  test "skips fee step when apply_fee is false" do
    result = Flows::TransferCredits.call(
      sender:    @alice,
      recipient: @bob,
      amount:    100,
      apply_fee: false
    )

    assert result.success?
    assert_equal 400, @alice.reload.credits
    assert_equal 300, @bob.reload.credits  # full 100 received

    logs = OperationLog.all.to_a
    assert_not logs.map(&:operation_name).include?("Flows::TransferCredits::ApplyFee"),
      "ApplyFee step should be skipped when apply_fee is false"
  end

  test "parent_reference_id links steps to the root" do
    Flows::TransferCredits.call(
      sender:    @alice,
      recipient: @bob,
      amount:    25
    )

    child_logs = OperationLog.where.not(parent_reference_id: nil).to_a

    assert child_logs.any?, "Should have child logs with parent_reference_id set"
    child_logs.each do |child|
      assert_not_nil child.parent_reference_id,
        "#{child.operation_name} should have a parent_reference_id"
    end
  end
end
