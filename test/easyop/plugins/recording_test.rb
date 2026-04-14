# frozen_string_literal: true

require 'test_helper'

class PluginsRecordingTest < Minitest::Test
  include EasyopTestHelper

  # Minimal fake model that mimics ActiveRecord column_names + create!
  class FakeModel
    COLUMNS = %w[operation_name success error_message params_data duration_ms performed_at].freeze

    attr_reader :records

    def initialize
      @records = []
    end

    def column_names
      COLUMNS
    end

    def create!(attrs)
      @records << attrs
    end
  end

  def model
    @model ||= FakeModel.new
  end

  def make_op(model: self.model, record_params: true, &call_block)
    m = model
    rp = record_params
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_params: rp
      define_method(:call, &call_block) if call_block
    end
    # Give it a name so skip-anonymous check passes
    klass
  end

  def named_op(model: self.model, &call_block)
    op = make_op(model: model, &call_block)
    # Assign constant name so self.class.name is non-nil
    set_const('TestRecordingOp', op)
    op
  end

  # ── Basic recording on success ─────────────────────────────────────────────────

  def test_records_successful_operation
    op = named_op { ctx[:out] = 1 }
    op.call(x: 1)
    assert_equal 1, model.records.size
    record = model.records.first
    assert_equal 'TestRecordingOp', record[:operation_name]
    assert_equal true,              record[:success]
    assert_nil   record[:error_message]
  end

  def test_records_failed_operation
    op = named_op { ctx.fail!(error: 'bad') }
    op.call
    record = model.records.first
    assert_equal false, record[:success]
    assert_equal 'bad', record[:error_message]
  end

  def test_records_duration_ms_as_float
    op = named_op { }
    op.call
    assert_instance_of Float, model.records.first[:duration_ms]
  end

  def test_records_performed_at
    op = named_op { }
    op.call
    assert_instance_of Time, model.records.first[:performed_at]
  end

  # ── params_data ───────────────────────────────────────────────────────────────

  def test_records_params_data_as_json_when_record_params_true
    op = named_op { }
    op.call(name: 'alice')
    pd = model.records.first[:params_data]
    assert_includes pd, 'alice'
  end

  def test_scrubs_sensitive_keys_from_params_data
    op = named_op { }
    op.call(password: 'secret', token: 'tok', name: 'alice')
    pd = model.records.first[:params_data]
    refute_includes pd, 'secret'
    refute_includes pd, 'tok'
    assert_includes pd, 'alice'
  end

  def test_skips_params_data_when_record_params_false
    op = make_op(record_params: false)
    set_const('TestRecordingNoPOp', op)
    op.call(name: 'bob')
    refute model.records.first.key?(:params_data)
  end

  # ── recording false opt-out ───────────────────────────────────────────────────

  def test_recording_false_skips_recording
    base = named_op { }
    child = Class.new(base) do
      recording false
    end
    set_const('TestRecordingChildOp', child)
    child.call
    assert_empty model.records
  end

  def test_recording_inherited_true_by_default
    parent = named_op { }
    child  = Class.new(parent)
    set_const('TestRecordingInheritedOp', child)
    child.call
    assert_equal 1, model.records.size
    assert_equal 'TestRecordingInheritedOp', model.records.first[:operation_name]
  end

  # ── Anonymous class skips recording ──────────────────────────────────────────

  def test_anonymous_class_skips_recording
    # Do NOT use set_const so class.name remains nil
    op = make_op { }
    op.call
    assert_empty model.records
  end

  # ── create! failure is swallowed ──────────────────────────────────────────────

  def test_model_create_failure_is_swallowed
    bad_model = FakeModel.new
    def bad_model.create!(_attrs)
      raise 'DB error'
    end
    op = make_op(model: bad_model) { }
    set_const('TestRecordingBadModelOp', op)
    op.call # must not raise
  end

  # ── Recording inside a flow also records (ensure branch) ─────────────────────

  def test_records_when_used_as_flow_step_that_fails
    op = named_op { ctx.fail!(error: 'step fail') }
    flow = Class.new { include Easyop::Flow }
    flow.flow(op)
    flow.call  # swallows failure
    assert_equal 1, model.records.size
    assert_equal false, model.records.first[:success]
  end
end
