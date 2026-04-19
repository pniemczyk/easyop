require "test_helper"

class Users::RegisterTest < ActiveSupport::TestCase
  setup do
    OperationLog.delete_all
  end

  test "successful registration creates user and operation log" do
    result = Users::Register.call(
      email:    "newuser@example.com",
      password: "secure_password123",
      name:     "New User"
    )

    assert result.success?, "Expected success but got: #{result[:error]}"
    assert_not_nil result.user
    assert result.user.persisted?
    assert_equal "newuser@example.com", result.user.email

    log = OperationLog.order(performed_at: :desc).first
    assert_equal "Users::Register", log.operation_name
    assert log.success?
  end

  test "params_data filters password as [FILTERED]" do
    Users::Register.call(
      email:    "filtered@example.com",
      password: "my_secret_password",
      name:     "Filter Test"
    )

    log = OperationLog.where(operation_name: "Users::Register").order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    assert_equal "[FILTERED]", params["password"],
      "Password should be filtered, not stored in plaintext"
    assert_equal "filtered@example.com", params["email"],
      "Email should be stored in params_data"
    assert_equal "Filter Test", params["name"]
  end

  test "result_data contains user AR reference" do
    Users::Register.call(
      email:    "result@example.com",
      password: "password123",
      name:     "Result Test"
    )

    log = OperationLog.where(operation_name: "Users::Register").order(performed_at: :desc).first
    assert_not_nil log.result_data, "result_data should be recorded (record_result true)"

    result = JSON.parse(log.result_data)
    assert_equal "User", result["user"]["class"],
      "Result data should contain the User class name"
    assert_not_nil result["user"]["id"],
      "Result data should contain the User id"
  end

  test "failed registration (duplicate email) records failure log" do
    # Use existing alice fixture
    Users::Register.call(
      email:    "alice@example.com",  # already exists
      password: "password123",
      name:     "Alice Clone"
    )

    log = OperationLog.where(operation_name: "Users::Register").order(performed_at: :desc).first
    assert_not log.success?
    assert_not_nil log.error_message
  end

  test "newsletter_opt_in default is false when not provided" do
    Users::Register.call(
      email:    "noopt@example.com",
      password: "password123",
      name:     "No Opt"
    )

    user = User.find_by(email: "noopt@example.com")
    assert_not user.newsletter_opt_in
  end
end
