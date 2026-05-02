# frozen_string_literal: true

require 'test_helper'

class SchemaTest < Minitest::Test
  include EasyopTestHelper

  def make_op(&setup_block)
    klass = Class.new do
      include Easyop::Operation
      def call; end
    end
    klass.instance_eval(&setup_block) if setup_block
    klass
  end

  # ── required params ───────────────────────────────────────────────────────────

  def test_required_param_missing_fails_ctx
    op = make_op { params { required :email } }
    result = op.call
    assert_predicate result, :failure?
    assert_includes result.error, 'email'
  end

  def test_required_param_present_succeeds
    op = make_op { params { required :email } }
    result = op.call(email: 'a@b.com')
    assert_predicate result, :success?
  end

  # ── optional params ───────────────────────────────────────────────────────────

  def test_optional_param_missing_succeeds
    op = make_op { params { optional :note } }
    result = op.call
    assert_predicate result, :success?
  end

  # ── defaults ─────────────────────────────────────────────────────────────────

  def test_optional_with_default_sets_value_when_absent
    op = make_op { params { optional :active, :boolean, default: false } }
    result = op.call
    assert_predicate result, :success?
    assert_equal false, result[:active]
  end

  def test_optional_with_proc_default
    op = make_op { params { optional :token, String, default: -> { 'generated' } } }
    result = op.call
    assert_equal 'generated', result[:token]
  end

  # ── type checking (strict_types: true) ────────────────────────────────────────

  def test_type_mismatch_with_strict_types_fails_ctx
    op = make_op { params { required :age, Integer } }
    Easyop.configure { |c| c.strict_types = true }
    result = op.call(age: 'not-an-int')
    assert_predicate result, :failure?
    assert_includes result.error, 'age'
  end

  def test_type_mismatch_without_strict_types_does_not_fail_ctx
    op = make_op { params { required :age, Integer } }
    Easyop.configure { |c| c.strict_types = false }
    result = op.call(age: 'not-an-int')
    assert_predicate result, :success?
  end

  def test_correct_type_with_strict_types_succeeds
    op = make_op { params { required :name, String } }
    Easyop.configure { |c| c.strict_types = true }
    result = op.call(name: 'alice')
    assert_predicate result, :success?
  end

  # ── type aliases ─────────────────────────────────────────────────────────────

  def test_type_mismatch_without_strict_types_warns_to_stderr
    op = make_op { params { required :age, Integer } }
    Easyop.configure { |c| c.strict_types = false }
    assert_output(nil, /Type mismatch/) { op.call(age: 'not-an-int') }
  end

  def test_boolean_type_alias_accepts_true_and_false
    op = make_op { params { required :flag, :boolean } }
    Easyop.configure { |c| c.strict_types = true }
    assert_predicate op.call(flag: true),  :success?
    assert_predicate op.call(flag: false), :success?
  end

  def test_boolean_type_alias_rejects_non_boolean
    op = make_op { params { required :flag, :boolean } }
    Easyop.configure { |c| c.strict_types = true }
    assert_predicate op.call(flag: 'yes'), :failure?
  end

  def test_string_type_alias
    op = make_op { params { required :msg, :string } }
    Easyop.configure { |c| c.strict_types = true }
    assert_predicate op.call(msg: 'hi'), :success?
  end

  def test_string_type_alias_rejects_non_string
    op = make_op { params { required :msg, :string } }
    Easyop.configure { |c| c.strict_types = true }
    assert_predicate op.call(msg: 42), :failure?
  end

  def test_integer_type_alias
    op = make_op { params { required :n, :integer } }
    Easyop.configure { |c| c.strict_types = true }
    assert_predicate op.call(n: 5), :success?
  end

  def test_any_type_alias_accepts_anything
    op = make_op { params { required :val, :any } }
    Easyop.configure { |c| c.strict_types = true }
    assert_predicate op.call(val: Object.new), :success?
  end

  def test_unknown_type_alias_raises_argument_error
    assert_raises(ArgumentError) do
      make_op { params { required :x, :unknown_type } }
    end
  end

  # ── result schema ─────────────────────────────────────────────────────────────

  def test_result_schema_validates_after_call
    op = make_op do
      result { required :output }
      define_method(:call) { ctx[:output] = 42 }
    end
    r = op.call
    assert_predicate r, :success?
  end

  def test_result_schema_fails_when_required_output_missing
    op = make_op { result { required :output } }
    r = op.call  # call is no-op, output never set
    assert_predicate r, :failure?
    assert_includes r.error, 'output'
  end

  def test_result_schema_skipped_on_failure
    op = make_op do
      result { required :output }
      define_method(:call) { ctx.fail!(error: 'bad') }
    end
    r = op.call
    assert_predicate r, :failure?
    assert_equal 'bad', r.error
  end

  # ── params alias (inputs) ────────────────────────────────────────────────────

  def test_inputs_is_alias_for_params
    op = make_op { inputs { required :name } }
    result = op.call(name: 'bob')
    assert_predicate result, :success?
  end

  def test_outputs_is_alias_for_result
    op = make_op do
      outputs { required :answer }
      define_method(:call) { ctx[:answer] = 42 }
    end
    result = op.call
    assert_predicate result, :success?
  end

  # ── FieldSchema#fields ────────────────────────────────────────────────────────

  def test_field_schema_fields_returns_defined_fields
    require 'easyop/schema'
    schema = Easyop::FieldSchema.new
    schema.required(:email, String)
    schema.optional(:role, String, default: 'user')
    assert_equal 2, schema.fields.length
    assert_equal [:email, :role], schema.fields.map(&:name)
  end

  def test_field_schema_fields_returns_dup
    require 'easyop/schema'
    schema = Easyop::FieldSchema.new
    schema.required(:name, String)
    original_count = schema.fields.length
    schema.fields << :extra  # mutate the returned copy
    assert_equal original_count, schema.fields.length
  end
end
