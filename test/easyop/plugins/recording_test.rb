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

  # ── Flow tracing helpers ──────────────────────────────────────────────────────

  TRACING_COLUMNS = %w[
    operation_name success error_message params_data duration_ms performed_at
    root_reference_id reference_id parent_operation_name parent_reference_id
  ].freeze

  class TracingModel
    attr_reader :records

    def initialize
      @records = []
    end

    def column_names
      TRACING_COLUMNS
    end

    def create!(attrs)
      @records << attrs
    end
  end

  def tracing_model
    @tracing_model ||= TracingModel.new
  end

  def named_tracing_op(name, &call_block)
    m = tracing_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      define_method(:call, &call_block) if call_block
    end
    set_const(name, klass)
    klass
  end

  def named_tracing_flow(name, *steps)
    m = tracing_model
    klass = Class.new do
      include Easyop::Flow
      flow(*steps)
    end
    klass.plugin(Easyop::Plugins::Recording, model: m)
    set_const(name, klass)
    klass
  end

  # ── Flow tracing: standalone operation ────────────────────────────────────────

  def test_tracing_standalone_generates_reference_ids
    named_tracing_op('TrStandaloneOp') { }
    tracing_model.records.clear
    Object.const_get('TrStandaloneOp').call(x: 1)
    rec = tracing_model.records.first
    assert_match(/\A[0-9a-f-]{36}\z/, rec[:root_reference_id].to_s)
    assert_match(/\A[0-9a-f-]{36}\z/, rec[:reference_id].to_s)
    assert_nil rec[:parent_operation_name]
    assert_nil rec[:parent_reference_id]
  end

  # ── Flow tracing: simple flow ─────────────────────────────────────────────────

  def test_tracing_simple_flow_records_three_entries
    step_a = named_tracing_op('TrSimpleStepA') { }
    step_b = named_tracing_op('TrSimpleStepB') { }
    named_tracing_flow('TrSimpleFlow', step_a, step_b)
    tracing_model.records.clear
    Object.const_get('TrSimpleFlow').call

    assert_equal 3, tracing_model.records.size
  end

  def test_tracing_simple_flow_all_share_root_reference_id
    step_a = named_tracing_op('TrRootStepA') { }
    step_b = named_tracing_op('TrRootStepB') { }
    named_tracing_flow('TrRootFlow', step_a, step_b)
    tracing_model.records.clear
    Object.const_get('TrRootFlow').call

    ids = tracing_model.records.map { |r| r[:root_reference_id] }.uniq
    assert_equal 1, ids.size
    refute_nil ids.first
  end

  def test_tracing_simple_flow_steps_have_flow_as_parent
    step_a = named_tracing_op('TrParentStepA') { }
    step_b = named_tracing_op('TrParentStepB') { }
    named_tracing_flow('TrParentFlow', step_a, step_b)
    tracing_model.records.clear
    Object.const_get('TrParentFlow').call

    flow_rec  = tracing_model.records.find { |r| r[:operation_name] == 'TrParentFlow' }
    step_a_rec = tracing_model.records.find { |r| r[:operation_name] == 'TrParentStepA' }
    step_b_rec = tracing_model.records.find { |r| r[:operation_name] == 'TrParentStepB' }

    assert_nil flow_rec[:parent_operation_name]
    assert_equal 'TrParentFlow', step_a_rec[:parent_operation_name]
    assert_equal flow_rec[:reference_id], step_a_rec[:parent_reference_id]
    assert_equal 'TrParentFlow', step_b_rec[:parent_operation_name]
    assert_equal flow_rec[:reference_id], step_b_rec[:parent_reference_id]
  end

  # ── Flow tracing: nested flows ────────────────────────────────────────────────

  def test_tracing_nested_flows_correct_parent_chain
    leaf  = named_tracing_op('TrNestedLeaf') { }
    inner = named_tracing_flow('TrNestedInner', leaf)
    named_tracing_flow('TrNestedOuter', inner)
    tracing_model.records.clear
    Object.const_get('TrNestedOuter').call

    outer_rec = tracing_model.records.find { |r| r[:operation_name] == 'TrNestedOuter' }
    inner_rec = tracing_model.records.find { |r| r[:operation_name] == 'TrNestedInner' }
    leaf_rec  = tracing_model.records.find { |r| r[:operation_name] == 'TrNestedLeaf' }

    # All share the same root
    ids = [outer_rec, inner_rec, leaf_rec].map { |r| r[:root_reference_id] }.uniq
    assert_equal 1, ids.size

    assert_nil outer_rec[:parent_operation_name]
    assert_equal 'TrNestedOuter', inner_rec[:parent_operation_name]
    assert_equal outer_rec[:reference_id], inner_rec[:parent_reference_id]
    assert_equal 'TrNestedInner', leaf_rec[:parent_operation_name]
    assert_equal inner_rec[:reference_id], leaf_rec[:parent_reference_id]
  end

  # ── Flow tracing: parent has recording false ──────────────────────────────────

  def test_tracing_child_acts_as_root_when_parent_recording_disabled
    child = named_tracing_op('TrDisabledChild') { }

    m = tracing_model
    parent_flow = Class.new do
      include Easyop::Flow
      flow child
    end
    parent_flow.plugin(Easyop::Plugins::Recording, model: m)
    parent_flow.recording false
    set_const('TrDisabledParent', parent_flow)

    tracing_model.records.clear
    Object.const_get('TrDisabledParent').call

    assert_equal 1, tracing_model.records.size
    rec = tracing_model.records.first
    refute_nil rec[:root_reference_id]
    assert_nil rec[:parent_operation_name]
    assert_nil rec[:parent_reference_id]
  end

  # ── Flow tracing: bare Flow (Recording not installed on the flow itself) ─────

  def test_tracing_bare_flow_records_only_steps
    step_a = named_tracing_op('BareStepA') { }
    step_b = named_tracing_op('BareStepB') { }

    # Bare Flow — Recording not installed, no named_tracing_flow helper (which adds plugin)
    bare = Class.new do
      include Easyop::Flow
      flow step_a, step_b
    end
    set_const('BareFlowClass', bare)

    tracing_model.records.clear
    bare.call

    assert_equal 2, tracing_model.records.size
    names = tracing_model.records.map { |r| r[:operation_name] }
    assert_includes names, 'BareStepA'
    assert_includes names, 'BareStepB'
  end

  def test_tracing_bare_flow_steps_share_root_reference_id
    step_a = named_tracing_op('BareRootStepA') { }
    step_b = named_tracing_op('BareRootStepB') { }

    bare = Class.new do
      include Easyop::Flow
      flow step_a, step_b
    end
    set_const('BareRootFlow', bare)

    tracing_model.records.clear
    bare.call

    ids = tracing_model.records.map { |r| r[:root_reference_id] }.uniq
    assert_equal 1, ids.size
    assert_match(/\A[0-9a-f-]{36}\z/, ids.first.to_s)
  end

  def test_tracing_bare_flow_steps_see_flow_as_parent
    step_a = named_tracing_op('BareParentStepA') { }
    step_b = named_tracing_op('BareParentStepB') { }

    bare = Class.new do
      include Easyop::Flow
      flow step_a, step_b
    end
    set_const('BareParentFlow', bare)

    tracing_model.records.clear
    bare.call

    rec_a = tracing_model.records.find { |r| r[:operation_name] == 'BareParentStepA' }
    rec_b = tracing_model.records.find { |r| r[:operation_name] == 'BareParentStepB' }

    assert_equal 'BareParentFlow', rec_a[:parent_operation_name]
    assert_equal 'BareParentFlow', rec_b[:parent_operation_name]

    # Both steps are siblings of the same bare-flow parent uuid
    assert_equal rec_a[:parent_reference_id], rec_b[:parent_reference_id]
    assert_match(/\A[0-9a-f-]{36}\z/, rec_a[:parent_reference_id].to_s)
  end

  # ── Flow tracing: internal keys excluded from params_data ─────────────────────

  def test_tracing_internal_keys_excluded_from_params_data
    named_tracing_op('TrParamsOp') { }
    tracing_model.records.clear
    Object.const_get('TrParamsOp').call(name: 'test')

    pd = JSON.parse(tracing_model.records.first[:params_data])
    pd.each_key do |k|
      refute k.start_with?('__recording_'), "params_data leaked internal key: #{k}"
    end
  end

  # ── Flow tracing: column filtering ────────────────────────────────────────────

  def test_tracing_columns_dropped_when_model_lacks_them
    slim_model = FakeModel.new  # uses only base COLUMNS, no tracing cols
    slim_op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: slim_model
    end
    set_const('TrSlimOp', slim_op)
    slim_op.call
    expect_keys = FakeModel::COLUMNS
    actual_keys = slim_model.records.first.keys.map(&:to_s)
    assert_equal expect_keys.sort, actual_keys.sort
  end

  # ── record_result helpers ─────────────────────────────────────────────────────

  ALL_COLUMNS = (TRACING_COLUMNS + %w[result_data]).freeze

  class ResultModel
    attr_reader :records

    def initialize
      @records = []
    end

    def column_names
      ALL_COLUMNS
    end

    def create!(attrs)
      @records << attrs
    end
  end

  def result_model
    @result_model ||= ResultModel.new
  end

  # config: a Proc or Symbol; attrs: keyword for the attrs form
  def named_result_op(name, config = nil, attrs: nil, plugin_record_result: nil, &call_block)
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: plugin_record_result
      define_method(:call, &call_block) if call_block
    end
    if attrs
      klass.record_result(attrs: attrs)
    elsif config.is_a?(Symbol)
      klass.record_result(config)
    elsif config.is_a?(Proc)
      klass.record_result(&config)
    end
    set_const(name, klass)
    klass
  end

  # ── record_result: attrs form (single key) ────────────────────────────────────

  def test_record_result_attrs_single_key
    named_result_op('RrAttrsOp', attrs: :info) { ctx.info = 'hello' }
    result_model.records.clear
    Object.const_get('RrAttrsOp').call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'info' => 'hello' }, data)
  end

  # ── record_result: attrs form (multiple keys) ─────────────────────────────────

  def test_record_result_attrs_multiple_keys
    named_result_op('RrMultiOp', attrs: [:info, :status]) do
      ctx.info   = 'a'
      ctx.status = 'b'
    end
    result_model.records.clear
    Object.const_get('RrMultiOp').call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'info' => 'a', 'status' => 'b' }, data)
  end

  # ── record_result: block form ─────────────────────────────────────────────────

  def test_record_result_block_form
    named_result_op('RrBlockOp', ->(c) { { computed: c.total * 2 } }) do
      ctx.total = 5
    end
    result_model.records.clear
    Object.const_get('RrBlockOp').call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'computed' => 10 }, data)
  end

  # ── record_result: symbol form ────────────────────────────────────────────────

  def test_record_result_symbol_form
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m

      record_result :build_result

      def call
        ctx.info = 'from method'
      end

      private

      def build_result
        { info: ctx.info }
      end
    end
    set_const('RrSymbolOp', klass)
    result_model.records.clear
    klass.call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'info' => 'from method' }, data)
  end

  # ── record_result: plugin-level default ───────────────────────────────────────

  def test_record_result_plugin_level_default
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: { attrs: :metadata }
      def call; ctx.metadata = 'meta-value'; end
    end
    set_const('RrPluginLevelOp', klass)
    result_model.records.clear
    klass.call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'metadata' => 'meta-value' }, data)
  end

  # ── record_result: class-level overrides plugin-level ────────────────────────

  def test_record_result_class_overrides_plugin_level
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: { attrs: :metadata }
      record_result attrs: :info
      def call; ctx.info = 'class'; ctx.metadata = 'plugin'; end
    end
    set_const('RrOverrideOp', klass)
    result_model.records.clear
    klass.call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'info' => 'class' }, data)
    refute data.key?('metadata')
  end

  # ── record_result: missing ctx key stores nil ─────────────────────────────────

  def test_record_result_missing_ctx_key_stores_nil
    named_result_op('RrMissingKeyOp', attrs: :nonexistent) { }
    result_model.records.clear
    Object.const_get('RrMissingKeyOp').call
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal({ 'nonexistent' => nil }, data)
  end

  # ── record_result: not configured → result_data absent ───────────────────────

  def test_record_result_not_configured_result_data_absent
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; ctx.info = 'x'; end
    end
    set_const('RrNoneOp', klass)
    result_model.records.clear
    klass.call
    refute result_model.records.first.key?(:result_data)
  end

  # ── record_result: model lacks result_data column — silently skipped ──────────

  def test_record_result_skipped_when_model_lacks_column
    m = FakeModel.new  # no result_data column
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result attrs: :info
      def call; ctx.info = 'x'; end
    end
    set_const('RrNoColOp', klass)
    klass.call  # must not raise
    refute m.records.first.key?(:result_data)
  end

  # ── record_result: serialization error is swallowed ───────────────────────────

  def test_record_result_serialization_error_swallowed
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result { |_c| raise 'boom' }
      def call; ctx.info = 'ok'; end
    end
    set_const('RrRaiseOp', klass)
    result_model.records.clear
    result = klass.call
    assert_predicate result, :success?
    assert_nil result_model.records.first[:result_data]
  end

  # ── record_result: child inherits parent config ───────────────────────────────

  def test_record_result_child_inherits_parent_config
    m = result_model
    parent = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result attrs: :info
      def call; ctx.info = 'parent'; end
    end
    set_const('RrInheritParent', parent)

    child = Class.new(parent) do
      def call; ctx.info = 'child-value'; end
    end
    set_const('RrInheritChild', child)

    result_model.records.clear
    child.call
    data = JSON.parse(result_model.records.last[:result_data])
    assert_equal({ 'info' => 'child-value' }, data)
  end
end
