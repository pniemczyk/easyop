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

  def test_filters_sensitive_keys_in_params_data
    op = named_op { }
    op.call(password: 'secret', token: 'tok', name: 'alice')
    data = JSON.parse(model.records.first[:params_data])
    assert_equal '[FILTERED]', data['password']
    assert_equal '[FILTERED]', data['token']
    assert_equal 'alice', data['name']
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

  TRACING_WITH_INDEX_COLUMNS = (TRACING_COLUMNS + %w[execution_index]).freeze

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

  # ── params_data records only INPUT keys (not computed results) ───────────────

  def test_params_data_excludes_keys_computed_during_call
    op = named_op { ctx.result_value = 'computed' }
    op.call(name: 'Alice')
    data = JSON.parse(model.records.first[:params_data])
    assert data.key?('name'), 'input key :name must appear in params_data'
    refute data.key?('result_value'), 'key set during call must NOT appear in params_data'
  end

  def test_params_data_includes_all_input_keys
    op = named_op { ctx.extra = 'added' }
    op.call(user_id: 42, action: 'create')
    data = JSON.parse(model.records.first[:params_data])
    assert_equal 42,       data['user_id']
    assert_equal 'create', data['action']
    refute data.key?('extra')
  end

  def test_params_data_still_filters_sensitive_input_keys
    op = named_op { }
    op.call(email: 'a@b.com', password: 's3cr3t')
    data = JSON.parse(model.records.first[:params_data])
    assert_equal 'a@b.com',    data['email']
    assert_equal '[FILTERED]', data['password']
  end

  def test_params_data_excludes_internal_ctx_keys_in_nested_op
    m = model
    child = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; end
    end
    set_const('InputNestedChildMT', child)

    parent_flow = Class.new { include Easyop::Flow }
    parent_flow.flow(child)
    set_const('InputNestedFlowMT', parent_flow)

    parent_flow.call(name: 'test')
    data = JSON.parse(m.records.first[:params_data])
    data.each_key { |k| refute k.start_with?('__recording_'), "leaked internal key: #{k}" }
    assert_equal 'test', data['name']
  end

  def test_params_data_attrs_form_can_include_computed_keys
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params attrs: :computed_result
      def call; ctx.computed_result = 'output'; end
    end
    set_const('InputAttrsComputedMT', op)
    op.call(name: 'Alice')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal 'output', data['computed_result']
    refute data.key?('name')
  end

  def test_params_data_block_form_can_include_computed_keys
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params { |c| { total: c[:total] } }
      def call; ctx.total = 99; end
    end
    set_const('InputBlockComputedMT', op)
    op.call(user_id: 1)
    data = JSON.parse(m.records.last[:params_data])
    assert_equal 99, data['total']
  end

  def test_record_result_true_still_captures_computed_keys
    m = FakeModel.new
    result_cols = FakeModel::COLUMNS + %w[result_data]
    m.define_singleton_method(:column_names) { result_cols }

    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result true
      def call; ctx.user = 'created_user'; end
    end
    set_const('InputResultFullMT', op)
    op.call(email: 'a@b.com')
    params = JSON.parse(m.records.first[:params_data])
    result = JSON.parse(m.records.first[:result_data])
    # params_data: only the input key
    assert_equal ['email'], params.keys
    # result_data: full ctx after execution — includes computed user
    assert_equal 'created_user', result['user']
    assert_equal 'a@b.com',      result['email']
  end

  # ── custom filter_keys ────────────────────────────────────────────────────────

  def test_filter_keys_plugin_install_symbol
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, filter_keys: [:api_token]
      def call; end
    end
    set_const('FilterInstallMT', op)
    op.call(name: 'Alice', api_token: 'tok_123')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['api_token']
    assert_equal 'Alice', data['name']
  end

  def test_filter_keys_plugin_install_regexp
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, filter_keys: [/token/i]
      def call; end
    end
    set_const('FilterRegexpMT', op)
    op.call(auth_token: 'abc', name: 'Bob')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['auth_token']
    assert_equal 'Bob', data['name']
  end

  def test_filter_params_class_dsl_symbol
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      filter_params :session_id
      def call; end
    end
    set_const('FilterDslMT', op)
    op.call(session_id: 'sess_xyz', name: 'Carol')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['session_id']
    assert_equal 'Carol', data['name']
  end

  def test_filter_params_class_dsl_regexp
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      filter_params(/private/i)
      def call; end
    end
    set_const('FilterDslRegexpMT', op)
    op.call(private_note: 'internal', name: 'Dave')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['private_note']
    assert_equal 'Dave', data['name']
  end

  def test_filter_params_inherited_additive
    m = model
    base = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      filter_params :base_secret
      def call; end
    end
    set_const('FilterBaseMT', base)
    child = Class.new(base) do
      filter_params :child_secret
    end
    set_const('FilterChildMT', child)

    child.call(base_secret: 'x', child_secret: 'y', name: 'Eve')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['base_secret'],  'base_secret should be filtered by child'
    assert_equal '[FILTERED]', data['child_secret'], 'child_secret should be filtered by child'
    assert_equal 'Eve', data['name']
  end

  def test_filter_keys_global_config_symbol
    Easyop.configure { |c| c.recording_filter_keys = [:global_secret] }
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; end
    end
    set_const('FilterGlobalMT', op)
    op.call(global_secret: 'x', name: 'Frank')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['global_secret']
    assert_equal 'Frank', data['name']
  end

  def test_filter_keys_global_config_regexp
    Easyop.configure { |c| c.recording_filter_keys = [/access.?key/i] }
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; end
    end
    set_const('FilterGlobalRegexpMT', op)
    op.call(access_key: 'k', name: 'Grace')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['access_key']
    assert_equal 'Grace', data['name']
  end

  def test_all_filter_layers_are_additive
    Easyop.configure { |c| c.recording_filter_keys = [:global_key] }
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, filter_keys: [:install_key]
      filter_params :class_key
      def call; end
    end
    set_const('FilterAllLayersMT', op)
    op.call(password: 'p', global_key: 'g', install_key: 'i', class_key: 'c', name: 'Heidi')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal '[FILTERED]', data['password'],    'built-in FILTERED_KEYS'
    assert_equal '[FILTERED]', data['global_key'],  'global config'
    assert_equal '[FILTERED]', data['install_key'], 'plugin install filter_keys'
    assert_equal '[FILTERED]', data['class_key'],   'class filter_params DSL'
    assert_equal 'Heidi', data['name']
  end

  # ── record_result: false (new default) ────────────────────────────────────────

  def test_record_result_default_false_result_data_absent
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; ctx.info = 'x'; end
    end
    set_const('RrDefaultFalseMT', klass)
    result_model.records.clear
    klass.call
    refute result_model.records.first.key?(:result_data)
  end

  def test_record_result_explicit_false_at_install_result_data_absent
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: false
      def call; ctx.info = 'x'; end
    end
    set_const('RrFalseInstallMT', klass)
    result_model.records.clear
    klass.call
    refute result_model.records.first.key?(:result_data)
  end

  # ── record_result: true — full ctx snapshot ───────────────────────────────────

  def test_record_result_true_at_install_persists_full_ctx
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: true
      def call; ctx.name = 'Alice'; ctx.score = 99; end
    end
    set_const('RrTrueInstallMT', klass)
    result_model.records.clear
    klass.call(name: 'Alice', score: 99)
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal 'Alice', data['name']
    assert_equal 99, data['score']
  end

  def test_record_result_true_at_install_filters_sensitive_keys
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: true
      def call; ctx.password = 's3cr3t'; ctx.name = 'Bob'; end
    end
    set_const('RrTrueInstallFilterMT', klass)
    result_model.records.clear
    klass.call(name: 'Bob', password: 's3cr3t')
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal '[FILTERED]', data['password']
    assert_equal 'Bob', data['name']
  end

  def test_record_result_true_at_install_excludes_internal_ctx_keys
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_result: true
      def call; end
    end
    set_const('RrTrueInstallInternalMT', klass)
    result_model.records.clear
    klass.call(name: 'test')
    data = JSON.parse(result_model.records.first[:result_data])
    data.each_key do |k|
      refute k.start_with?('__recording_'), "result_data leaked internal key: #{k}"
    end
  end

  def test_record_result_true_dsl_persists_full_ctx
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result true
      def call; ctx.value = 42; end
    end
    set_const('RrTrueDslMT', klass)
    result_model.records.clear
    klass.call(value: 42)
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal 42, data['value']
  end

  def test_record_result_true_dsl_applies_filtered_keys
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result true
      def call; ctx.token = 'tok'; ctx.user = 'Alice'; end
    end
    set_const('RrTrueDslFilterMT', klass)
    result_model.records.clear
    klass.call(user: 'Alice', token: 'tok')
    data = JSON.parse(result_model.records.first[:result_data])
    assert_equal '[FILTERED]', data['token']
    assert_equal 'Alice', data['user']
  end

  def test_record_result_true_dsl_excludes_internal_keys
    m = result_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result true
      def call; end
    end
    set_const('RrTrueDslInternalMT', klass)
    result_model.records.clear
    klass.call(name: 'x')
    data = JSON.parse(result_model.records.first[:result_data])
    data.each_key do |k|
      refute k.start_with?('__recording_'), "result_data leaked internal key: #{k}"
    end
  end

  def test_record_result_true_inherited_by_child
    m = result_model
    parent = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_result true
      def call; ctx.info = 'parent'; end
    end
    set_const('RrTrueInheritParentMT', parent)
    child = Class.new(parent) do
      def call; ctx.info = 'child'; end
    end
    set_const('RrTrueInheritChildMT', child)
    result_model.records.clear
    child.call
    data = JSON.parse(result_model.records.last[:result_data])
    assert_equal 'child', data['info']
  end

  def test_record_result_child_overrides_false_with_true
    m = result_model
    parent = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      # default false — no record_result configured
      def call; ctx.info = 'x'; end
    end
    set_const('RrFalseParentMT', parent)
    child = Class.new(parent) do
      record_result true
      def call; ctx.info = 'child-result'; end
    end
    set_const('RrTrueChildMT', child)
    result_model.records.clear
    child.call
    data = JSON.parse(result_model.records.last[:result_data])
    assert_equal 'child-result', data['info']
  end

  # ── record_params DSL and install-level forms ─────────────────────────────────

  def test_dot_record_params_install_hash_single_attr
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_params: { attrs: :name }
      def call; end
    end
    set_const('RpInstallHashSingleMT', op)
    op.call(name: 'Alice', password: 'secret')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal ['name'], data.keys
    assert_equal 'Alice', data['name']
  end

  def test_dot_record_params_install_hash_multiple_attrs
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_params: { attrs: [:name, :email] }
      def call; end
    end
    set_const('RpInstallHashMultiMT', op)
    op.call(name: 'Alice', email: 'a@b.com', password: 'secret')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal %w[email name], data.keys.sort
    assert_equal 'Alice', data['name']
    assert_equal 'a@b.com', data['email']
  end

  def test_dot_record_params_install_proc
    m = model
    extractor = ->(c) { { custom: c[:name].upcase } }
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_params: extractor
      def call; end
    end
    set_const('RpInstallProcMT', op)
    op.call(name: 'alice')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal({ 'custom' => 'ALICE' }, data)
  end

  def test_dot_record_params_install_symbol
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m, record_params: :build_params_method

      def call; end

      private

      def build_params_method
        { extracted: ctx[:name] }
      end
    end
    set_const('RpInstallSymbolMT', op)
    op.call(name: 'Bob')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal({ 'extracted' => 'Bob' }, data)
  end

  def test_dot_record_params_dsl_attrs_single_key
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params attrs: :email
      def call; end
    end
    set_const('RpDslAttrsMT', op)
    op.call(email: 'x@y.com', password: 's')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal ['email'], data.keys
    assert_equal 'x@y.com', data['email']
  end

  def test_dot_record_params_dsl_block
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params { |c| { user: c[:name] } }
      def call; end
    end
    set_const('RpDslBlockMT', op)
    op.call(name: 'Charlie')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal({ 'user' => 'Charlie' }, data)
  end

  def test_dot_record_params_dsl_symbol
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params :safe_params_method

      def call; end

      private

      def safe_params_method
        { user_id: ctx[:id] }
      end
    end
    set_const('RpDslSymbolMT', op)
    op.call(id: 7, password: 'secret')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal({ 'user_id' => 7 }, data)
  end

  def test_dot_record_params_dsl_false_skips_params_data
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params false
      def call; end
    end
    set_const('RpDslFalseMT', op)
    op.call(name: 'Alice')
    refute m.records.last.key?(:params_data)
  end

  def test_dot_record_params_dsl_true_writes_full_ctx
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params true
      def call; end
    end
    set_const('RpDslTrueMT', op)
    op.call(name: 'Alice', role: 'admin')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal 'Alice', data['name']
    assert_equal 'admin', data['role']
  end

  def test_dot_record_params_filtered_keys_apply_to_attrs_form
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params attrs: [:name, :password]
      def call; end
    end
    set_const('RpAttrsFilterMT', op)
    op.call(name: 'Alice', password: 's3cr3t')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal 'Alice', data['name']
    assert_equal '[FILTERED]', data['password']
  end

  def test_dot_record_params_filtered_keys_apply_to_block_form
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params { |c| { name: c[:name], token: c[:token] } }
      def call; end
    end
    set_const('RpBlockFilterMT', op)
    op.call(name: 'Alice', token: 'tok_abc')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal 'Alice', data['name']
    assert_equal '[FILTERED]', data['token']
  end

  def test_dot_record_params_filtered_keys_apply_to_symbol_form
    m = model
    op = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params :extract_params_method

      def call; end

      private

      def extract_params_method
        { name: ctx[:name], secret: ctx[:secret] }
      end
    end
    set_const('RpSymbolFilterMT', op)
    op.call(name: 'Alice', secret: 'shh')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal 'Alice', data['name']
    assert_equal '[FILTERED]', data['secret']
  end

  def test_dot_record_params_config_inherited_by_child
    m = model
    parent = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params attrs: :name
      def call; end
    end
    set_const('RpInheritParentMT', parent)
    child = Class.new(parent) do
      def call; end
    end
    set_const('RpInheritChildMT', child)
    child.call(name: 'Alice', email: 'a@b.com')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal ['name'], data.keys
    assert_equal 'Alice', data['name']
  end

  def test_dot_record_params_child_overrides_parent_config
    m = model
    parent = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      record_params attrs: :name
      def call; end
    end
    set_const('RpOverrideParentMT', parent)
    child = Class.new(parent) do
      record_params attrs: :email
      def call; end
    end
    set_const('RpOverrideChildMT', child)
    child.call(name: 'Alice', email: 'a@b.com')
    data = JSON.parse(m.records.last[:params_data])
    assert_equal ['email'], data.keys
    assert_equal 'a@b.com', data['email']
    refute data.key?('name')
  end

  # ── execution_index helpers ───────────────────────────────────────────────────

  class TracingWithIndexModel
    attr_reader :records

    def initialize
      @records = []
    end

    def column_names
      TRACING_WITH_INDEX_COLUMNS
    end

    def create!(attrs)
      @records << attrs
    end
  end

  def idx_model
    @idx_model ||= TracingWithIndexModel.new
  end

  def named_idx_op(name, &call_block)
    m = idx_model
    klass = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      define_method(:call, &call_block) if call_block
    end
    set_const(name, klass)
    klass
  end

  def named_idx_flow(name, *steps)
    m = idx_model
    klass = Class.new { include Easyop::Flow; flow(*steps) }
    klass.plugin(Easyop::Plugins::Recording, model: m)
    set_const(name, klass)
    klass
  end

  # ── execution_index: model without column ─────────────────────────────────────

  def test_execution_index_omitted_when_model_lacks_column
    op = named_tracing_op('ExIdxNoColMT') { }
    tracing_model.records.clear
    Object.const_get('ExIdxNoColMT').call
    refute tracing_model.records.first.key?(:execution_index),
           'execution_index must not appear when model lacks the column'
  end

  # ── execution_index: root operation ──────────────────────────────────────────

  def test_execution_index_nil_for_standalone_root
    named_idx_op('ExIdxRootMT') { }
    idx_model.records.clear
    Object.const_get('ExIdxRootMT').call
    assert_nil idx_model.records.first[:execution_index]
  end

  # ── execution_index: two siblings ────────────────────────────────────────────

  def test_execution_index_two_siblings_ordered_1_2
    sa = named_idx_op('ExIdx2A') { }
    sb = named_idx_op('ExIdx2B') { }
    named_idx_flow('ExIdx2Flow', sa, sb)
    idx_model.records.clear
    Object.const_get('ExIdx2Flow').call

    rec_a = idx_model.records.find { |r| r[:operation_name] == 'ExIdx2A' }
    rec_b = idx_model.records.find { |r| r[:operation_name] == 'ExIdx2B' }
    assert_equal 1, rec_a[:execution_index]
    assert_equal 2, rec_b[:execution_index]
  end

  # ── execution_index: root flow has nil index ──────────────────────────────────

  def test_execution_index_nil_for_root_flow
    sa = named_idx_op('ExIdxFlowRootA') { }
    named_idx_flow('ExIdxFlowRootFlow', sa)
    idx_model.records.clear
    Object.const_get('ExIdxFlowRootFlow').call
    flow_rec = idx_model.records.find { |r| r[:operation_name] == 'ExIdxFlowRootFlow' }
    assert_nil flow_rec[:execution_index]
  end

  # ── execution_index: three siblings ──────────────────────────────────────────

  def test_execution_index_three_siblings_ordered_1_2_3
    sa = named_idx_op('ExIdx3AMT') { }
    sb = named_idx_op('ExIdx3BMT') { }
    sc = named_idx_op('ExIdx3CMT') { }
    named_idx_flow('ExIdx3FlowMT', sa, sb, sc)
    idx_model.records.clear
    Object.const_get('ExIdx3FlowMT').call

    indices = %w[ExIdx3AMT ExIdx3BMT ExIdx3CMT].map do |n|
      idx_model.records.find { |r| r[:operation_name] == n }[:execution_index]
    end
    assert_equal [1, 2, 3], indices
  end

  # ── execution_index: grandchildren reset under new parent ────────────────────
  # Tree: Root > [B(1), C(2) > [D(1), E(2)], F(3)]

  def test_execution_index_nested_flow_full_tree
    mb = named_idx_op('ExIdxNstBMT') { }
    md = named_idx_op('ExIdxNstDMT') { }
    me = named_idx_op('ExIdxNstEMT') { }
    mf = named_idx_op('ExIdxNstFMT') { }

    inner_c = Class.new { include Easyop::Flow; flow md, me }
    inner_c.plugin(Easyop::Plugins::Recording, model: idx_model)
    set_const('ExIdxNstCMT', inner_c)

    root_flow = Class.new { include Easyop::Flow; flow mb, inner_c, mf }
    root_flow.plugin(Easyop::Plugins::Recording, model: idx_model)
    set_const('ExIdxNstRootMT', root_flow)

    idx_model.records.clear
    root_flow.call

    assert_nil idx_model.records.find { |r| r[:operation_name] == 'ExIdxNstRootMT' }[:execution_index], 'Root index should be nil'
    assert_equal 1, idx_model.records.find { |r| r[:operation_name] == 'ExIdxNstBMT' }[:execution_index], 'B should be 1st child of Root'
    assert_equal 2, idx_model.records.find { |r| r[:operation_name] == 'ExIdxNstCMT' }[:execution_index], 'C should be 2nd child of Root'
    assert_equal 3, idx_model.records.find { |r| r[:operation_name] == 'ExIdxNstFMT' }[:execution_index], 'F should be 3rd child of Root'
    assert_equal 1, idx_model.records.find { |r| r[:operation_name] == 'ExIdxNstDMT' }[:execution_index], 'D should be 1st child of C'
    assert_equal 2, idx_model.records.find { |r| r[:operation_name] == 'ExIdxNstEMT' }[:execution_index], 'E should be 2nd child of C'
  end

  # ── execution_index: bare flow (Recording not on flow) ───────────────────────

  def test_execution_index_bare_flow_steps_get_correct_indices
    m = idx_model
    sa = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; end
    end
    set_const('ExIdxBareAMT', sa)

    sb = Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Recording, model: m
      def call; end
    end
    set_const('ExIdxBareBMT', sb)

    bare = Class.new { include Easyop::Flow; flow sa, sb }
    set_const('ExIdxBareFlowMT', bare)

    idx_model.records.clear
    bare.call

    rec_a = idx_model.records.find { |r| r[:operation_name] == 'ExIdxBareAMT' }
    rec_b = idx_model.records.find { |r| r[:operation_name] == 'ExIdxBareBMT' }
    assert_equal 1, rec_a[:execution_index]
    assert_equal 2, rec_b[:execution_index]
  end

  # ── execution_index: sibling with recording false skips slot ──────────────────

  def test_execution_index_skips_slot_for_recording_false_sibling
    sa = named_idx_op('ExIdxSkipAMT') { }
    sb_klass = named_idx_op('ExIdxSkipBMT') { }
    sb_klass.recording false
    sc = named_idx_op('ExIdxSkipCMT') { }

    named_idx_flow('ExIdxSkipFlowMT', sa, sb_klass, sc)
    idx_model.records.clear
    Object.const_get('ExIdxSkipFlowMT').call

    rec_a = idx_model.records.find { |r| r[:operation_name] == 'ExIdxSkipAMT' }
    rec_c = idx_model.records.find { |r| r[:operation_name] == 'ExIdxSkipCMT' }
    assert_equal 1, rec_a[:execution_index], 'A should still be 1'
    assert_equal 2, rec_c[:execution_index], 'C should be 2 (B slot skipped)'
    refute idx_model.records.any? { |r| r[:operation_name] == 'ExIdxSkipBMT' }, 'B must not be recorded'
  end

  # ── execution_index: __recording_child_counts excluded from params_data ───────

  def test_execution_index_child_counts_key_excluded_from_params_data
    sa = named_idx_op('ExIdxLeakAMT') { }
    sb = named_idx_op('ExIdxLeakBMT') { }
    named_idx_flow('ExIdxLeakFlowMT', sa, sb)
    idx_model.records.clear
    Object.const_get('ExIdxLeakFlowMT').call

    idx_model.records.each do |rec|
      next unless rec[:params_data]
      data = JSON.parse(rec[:params_data])
      data.each_key do |k|
        refute k.start_with?('__recording_'), "params_data leaked internal key: #{k}"
      end
    end
  end
end
