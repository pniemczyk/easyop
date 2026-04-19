require "test_helper"

class Articles::CreateTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    OperationLog.delete_all
  end

  test "creates article and records operation log" do
    result = Articles::Create.call(
      title:     "Test Article",
      body:      "This is the body of the test article.",
      user:      @alice,
      published: false
    )

    assert result.success?, "Expected success but got: #{result[:error]}"
    assert_not_nil result.article
    assert result.article.persisted?
    assert_equal "Test Article", result.article.title

    log = OperationLog.order(performed_at: :desc).first
    assert_equal "Articles::Create", log.operation_name
    assert log.success?
  end

  test "params_data records user as AR reference" do
    Articles::Create.call(
      title: "Params Test",
      body:  "Body content",
      user:  @alice
    )

    log = OperationLog.where(operation_name: "Articles::Create").order(performed_at: :desc).first
    params = JSON.parse(log.params_data)

    assert_equal "User", params["user"]["class"],
      "User should be serialized as {class:, id:} in params_data"
    assert_equal @alice.id, params["user"]["id"]
    assert_equal "Params Test", params["title"]
  end

  test "result_data records article reference" do
    Articles::Create.call(
      title: "Result Test",
      body:  "Body content",
      user:  @alice
    )

    log = OperationLog.where(operation_name: "Articles::Create").order(performed_at: :desc).first
    assert_not_nil log.result_data

    result = JSON.parse(log.result_data)
    assert_equal "Article", result["article"]["class"]
    assert_not_nil result["article"]["id"]
  end

  test "publishes immediately when published: true" do
    result = Articles::Create.call(
      title:     "Published Now",
      body:      "Content",
      user:      @alice,
      published: true
    )

    assert result.success?
    assert result.article.published?
    assert_not_nil result.article.published_at
  end

  test "failure records error in operation log" do
    # Empty title should fail validation
    result = Articles::Create.call(
      title: "",
      body:  "Body",
      user:  @alice
    )

    assert result.failure?

    log = OperationLog.where(operation_name: "Articles::Create").order(performed_at: :desc).first
    assert_not log.success?
    assert_not_nil log.error_message
  end
end
