# frozen_string_literal: true

require "test_helper"

class Easyop::Testing::RecordingAssertionsTest < Minitest::Test
  include EasyopTestHelper
  include Easyop::Testing::Assertions
  include Easyop::Testing::RecordingAssertions

  # ── helpers ───────────────────────────────────────────────────────────────────

  def model
    @model ||= Easyop::Testing::FakeModel.new
  end

  # Build a named operation that uses Recording with our spy model.
  def make_op(record_params: true, record_result: false, encrypt_keys: [], filter_keys: [], &call_block)
    m   = model
    rp  = record_params
    rr  = record_result
    ek  = encrypt_keys
    fk  = filter_keys
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording,
             model: m,
             record_params: rp,
             record_result: rr,
             encrypt_keys: ek,
             filter_keys: fk
      define_method(:call, &call_block) if call_block
    end
    # Must have a name for Recording to run
    set_const("TestRecordingAssertOp", klass)
    klass
  end

  def teardown
    model.clear!
    super
  end

  # ── assert_recorded_success ───────────────────────────────────────────────────

  def test_assert_recorded_success_passes_when_last_record_is_success
    op = make_op { }
    op.call
    assert_silent { assert_recorded_success(model) }
  end

  def test_assert_recorded_success_fails_when_last_record_is_failure
    op = make_op { ctx.fail!(error: "oops") }
    op.call
    assert_raises(Minitest::Assertion) { assert_recorded_success(model) }
  end

  # ── assert_recorded_failure ───────────────────────────────────────────────────

  def test_assert_recorded_failure_passes_when_last_record_is_failure
    op = make_op { ctx.fail!(error: "bad thing") }
    op.call
    assert_silent { assert_recorded_failure(model) }
  end

  def test_assert_recorded_failure_fails_when_last_record_is_success
    op = make_op { }
    op.call
    assert_raises(Minitest::Assertion) { assert_recorded_failure(model) }
  end

  def test_assert_recorded_failure_with_matching_error_message
    op = make_op { ctx.fail!(error: "Insufficient credits") }
    op.call
    assert_silent { assert_recorded_failure(model, error: "Insufficient credits") }
  end

  def test_assert_recorded_failure_with_wrong_error_message_raises
    op = make_op { ctx.fail!(error: "Wrong message") }
    op.call
    assert_raises(Minitest::Assertion) { assert_recorded_failure(model, error: "Different") }
  end

  # ── assert_params_recorded ────────────────────────────────────────────────────

  def test_assert_params_recorded_passes_when_key_exists
    op = make_op { }
    op.call(email: "a@b.com")
    assert_silent { assert_params_recorded(model, :email) }
  end

  def test_assert_params_recorded_fails_when_key_absent
    op = make_op { }
    op.call(email: "a@b.com")
    assert_raises(Minitest::Assertion) { assert_params_recorded(model, :missing_key) }
  end

  def test_assert_params_recorded_with_value_passes_when_value_matches
    op = make_op { }
    op.call(amount: 100)
    assert_silent { assert_params_recorded(model, :amount, 100) }
  end

  def test_assert_params_recorded_with_value_fails_when_value_differs
    op = make_op { }
    op.call(amount: 100)
    assert_raises(Minitest::Assertion) { assert_params_recorded(model, :amount, 999) }
  end

  # ── assert_params_filtered ────────────────────────────────────────────────────

  def test_assert_params_filtered_passes_when_value_is_filtered
    # :password is a built-in filtered key
    op = make_op { }
    op.call(password: "secret")
    assert_silent { assert_params_filtered(model, :password) }
  end

  def test_assert_params_filtered_fails_when_value_is_not_filtered
    op = make_op { }
    op.call(email: "plain@example.com")
    assert_raises(Minitest::Assertion) { assert_params_filtered(model, :email) }
  end

  def test_assert_params_filtered_with_custom_filter_key
    op = make_op(filter_keys: [:api_token]) { }
    op.call(api_token: "my-secret-token")
    assert_silent { assert_params_filtered(model, :api_token) }
  end

  # ── assert_params_encrypted ───────────────────────────────────────────────────

  def test_assert_params_encrypted_passes_when_value_is_encrypted
    with_recording_secret("a_test_secret_that_is_32_bytes!!") do
      op = make_op(encrypt_keys: [:credit_card]) { }
      op.call(credit_card: "4242424242424242")
      assert_silent { assert_params_encrypted(model, :credit_card) }
    end
  end

  def test_assert_params_encrypted_fails_when_value_is_plain
    op = make_op { }
    op.call(email: "plain@example.com")
    assert_raises(Minitest::Assertion) { assert_params_encrypted(model, :email) }
  end

  # ── assert_result_recorded ────────────────────────────────────────────────────

  def test_assert_result_recorded_passes_when_key_exists
    op = make_op(record_result: true) { ctx[:order_id] = 42 }
    op.call
    assert_silent { assert_result_recorded(model, :order_id) }
  end

  def test_assert_result_recorded_fails_when_key_absent
    op = make_op(record_result: true) { ctx[:order_id] = 42 }
    op.call
    assert_raises(Minitest::Assertion) { assert_result_recorded(model, :missing_key) }
  end

  def test_assert_result_recorded_with_value_passes
    op = make_op(record_result: true) { ctx[:order_id] = 42 }
    op.call
    assert_silent { assert_result_recorded(model, :order_id, 42) }
  end

  # ── assert_ar_ref_in_params ───────────────────────────────────────────────────

  def test_assert_ar_ref_in_params_passes_for_ar_style_hash
    # Manually inject a record with an AR-style reference in params_data
    model.create!(
      operation_name: "TestRecordingAssertOp",
      success: true,
      params_data: '{"user":{"class":"User","id":42}}'
    )
    assert_silent { assert_ar_ref_in_params(model, :user, class_name: "User") }
  end

  def test_assert_ar_ref_in_params_with_id_passes
    model.create!(
      operation_name: "TestRecordingAssertOp",
      success: true,
      params_data: '{"user":{"class":"User","id":42}}'
    )
    assert_silent { assert_ar_ref_in_params(model, :user, class_name: "User", id: 42) }
  end

  def test_assert_ar_ref_in_params_with_wrong_id_fails
    model.create!(
      operation_name: "TestRecordingAssertOp",
      success: true,
      params_data: '{"user":{"class":"User","id":42}}'
    )
    assert_raises(Minitest::Assertion) do
      assert_ar_ref_in_params(model, :user, class_name: "User", id: 999)
    end
  end

  def test_assert_ar_ref_in_params_fails_when_not_ar_hash
    model.create!(
      operation_name: "TestRecordingAssertOp",
      success: true,
      params_data: '{"user":"not_an_ar_ref"}'
    )
    assert_raises(Minitest::Assertion) do
      assert_ar_ref_in_params(model, :user, class_name: "User")
    end
  end

  # ── decrypt_recorded_param ────────────────────────────────────────────────────

  def test_decrypt_recorded_param_returns_plaintext
    secret = "a_test_secret_that_is_32_bytes!!"
    with_recording_secret(secret) do
      op = make_op(encrypt_keys: [:card_number]) { }
      op.call(card_number: "4111111111111111")
      plain = decrypt_recorded_param(model, :card_number)
      assert_equal "4111111111111111", plain
    end
  end

  # ── with_recording_secret ─────────────────────────────────────────────────────

  def test_with_recording_secret_sets_and_restores_secret
    original = Easyop.config.recording_secret
    used_inside = nil

    with_recording_secret("a_test_secret_that_is_32_bytes!!") do
      used_inside = Easyop.config.recording_secret
    end

    assert_equal "a_test_secret_that_is_32_bytes!!", used_inside
    assert_equal original, Easyop.config.recording_secret
  end

  def test_with_recording_secret_restores_secret_on_exception
    original = Easyop.config.recording_secret

    assert_raises(RuntimeError) do
      with_recording_secret("a_test_secret_that_is_32_bytes!!") do
        raise "intentional error"
      end
    end

    assert_equal original, Easyop.config.recording_secret
  end
end
