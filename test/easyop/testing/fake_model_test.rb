# frozen_string_literal: true

require "test_helper"

class Easyop::Testing::FakeModelTest < Minitest::Test
  def model
    @model ||= Easyop::Testing::FakeModel.new
  end

  # ── column_names ──────────────────────────────────────────────────────────────

  def test_column_names_returns_standard_columns
    expected = %w[
      operation_name success error_message params_data result_data
      duration_ms performed_at root_reference_id reference_id
      parent_operation_name parent_reference_id execution_index
    ]
    assert_equal expected, model.column_names
  end

  def test_column_names_includes_extra_columns
    m = Easyop::Testing::FakeModel.new(extra_columns: [:custom_col, "another_col"])
    assert_includes m.column_names, "custom_col"
    assert_includes m.column_names, "another_col"
  end

  # ── create! ───────────────────────────────────────────────────────────────────

  def test_create_stores_a_record
    model.create!(operation_name: "MyOp", success: true)
    assert_equal 1, model.count
  end

  def test_create_returns_the_stored_record
    record = model.create!(operation_name: "MyOp", success: true)
    assert_equal :MyOp, :MyOp  # sanity
    assert_equal "MyOp", record[:operation_name]
  end

  def test_create_converts_string_keys_to_symbols
    record = model.create!("operation_name" => "MyOp")
    assert record.key?(:operation_name), "Expected symbol key :operation_name"
  end

  # ── count / any? / empty? ─────────────────────────────────────────────────────

  def test_count_returns_zero_initially
    assert_equal 0, model.count
  end

  def test_any_returns_false_initially
    refute model.any?
  end

  def test_empty_returns_true_initially
    assert model.empty?
  end

  def test_count_increments_after_create
    model.create!(operation_name: "Op1", success: true)
    model.create!(operation_name: "Op2", success: false)
    assert_equal 2, model.count
  end

  def test_any_returns_true_after_create
    model.create!(operation_name: "Op", success: true)
    assert model.any?
  end

  def test_empty_returns_false_after_create
    model.create!(operation_name: "Op", success: true)
    refute model.empty?
  end

  # ── first / last ─────────────────────────────────────────────────────────────

  def test_first_returns_nil_when_empty
    assert_nil model.first
  end

  def test_last_returns_nil_when_empty
    assert_nil model.last
  end

  def test_first_returns_earliest_record
    model.create!(operation_name: "First", success: true)
    model.create!(operation_name: "Second", success: true)
    assert_equal "First", model.first[:operation_name]
  end

  def test_last_returns_most_recent_record
    model.create!(operation_name: "First", success: true)
    model.create!(operation_name: "Second", success: true)
    assert_equal "Second", model.last[:operation_name]
  end

  # ── last_params ───────────────────────────────────────────────────────────────

  def test_last_params_returns_empty_hash_when_no_records
    assert_equal({}, model.last_params)
  end

  def test_last_params_returns_empty_hash_when_params_data_is_nil
    model.create!(operation_name: "Op", success: true, params_data: nil)
    assert_equal({}, model.last_params)
  end

  def test_last_params_returns_empty_hash_when_params_data_is_empty_string
    model.create!(operation_name: "Op", success: true, params_data: "")
    assert_equal({}, model.last_params)
  end

  def test_last_params_parses_json_from_params_data
    model.create!(operation_name: "Op", success: true, params_data: '{"email":"a@b.com","amount":100}')
    assert_equal({ "email" => "a@b.com", "amount" => 100 }, model.last_params)
  end

  # ── last_result ───────────────────────────────────────────────────────────────

  def test_last_result_returns_empty_hash_when_no_records
    assert_equal({}, model.last_result)
  end

  def test_last_result_returns_empty_hash_when_result_data_is_nil
    model.create!(operation_name: "Op", success: true, result_data: nil)
    assert_equal({}, model.last_result)
  end

  def test_last_result_parses_json_from_result_data
    model.create!(operation_name: "Op", success: true, result_data: '{"order_id":42}')
    assert_equal({ "order_id" => 42 }, model.last_result)
  end

  # ── params_at / result_at ─────────────────────────────────────────────────────

  def test_params_at_returns_parsed_params_for_given_index
    model.create!(operation_name: "Op1", success: true, params_data: '{"x":1}')
    model.create!(operation_name: "Op2", success: true, params_data: '{"x":2}')
    assert_equal({ "x" => 1 }, model.params_at(0))
    assert_equal({ "x" => 2 }, model.params_at(1))
  end

  def test_result_at_returns_parsed_result_for_given_index
    model.create!(operation_name: "Op1", success: true, result_data: '{"y":10}')
    model.create!(operation_name: "Op2", success: true, result_data: '{"y":20}')
    assert_equal({ "y" => 10 }, model.result_at(0))
    assert_equal({ "y" => 20 }, model.result_at(1))
  end

  def test_params_at_returns_empty_hash_when_params_data_nil
    model.create!(operation_name: "Op", success: true, params_data: nil)
    assert_equal({}, model.params_at(0))
  end

  # ── records_for ───────────────────────────────────────────────────────────────

  def test_records_for_filters_by_operation_name
    model.create!(operation_name: "MyOp", success: true)
    model.create!(operation_name: "OtherOp", success: true)
    model.create!(operation_name: "MyOp", success: false)

    results = model.records_for("MyOp")
    assert_equal 2, results.size
    assert results.all? { |r| r[:operation_name] == "MyOp" }
  end

  def test_records_for_returns_empty_array_when_no_match
    model.create!(operation_name: "MyOp", success: true)
    assert_empty model.records_for("NonExistentOp")
  end

  # ── clear! ────────────────────────────────────────────────────────────────────

  def test_clear_empties_records
    model.create!(operation_name: "Op1", success: true)
    model.create!(operation_name: "Op2", success: true)
    model.clear!
    assert model.empty?
    assert_equal 0, model.count
  end

  def test_clear_returns_the_model
    result = model.clear!
    assert_same model, result
  end

  # ── all ───────────────────────────────────────────────────────────────────────

  def test_all_returns_copy_of_records
    model.create!(operation_name: "Op1", success: true)
    all_records = model.all
    assert_equal 1, all_records.size
    # Ensure it's a copy, not the internal array
    all_records.clear
    assert_equal 1, model.count
  end
end
