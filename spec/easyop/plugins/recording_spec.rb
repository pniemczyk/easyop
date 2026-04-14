# Minimal ActiveRecord::Base stub — no gem required
module ActiveRecord
  class Base; end
end

# Time.current is an ActiveSupport convenience; stub it so recording_persist!
# does not raise NoMethodError (which would be silently swallowed).
class Time
  def self.current
    now
  end
end

require "spec_helper"
require "easyop/plugins/recording"

RSpec.describe Easyop::Plugins::Recording do
  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      class_eval(&blk) if blk
    end
  end

  def fake_model(columns: %w[operation_name success error_message params_data duration_ms performed_at])
    klass = Class.new
    klass.instance_variable_set(:@columns, columns)
    klass.instance_variable_set(:@records, [])
    klass.define_singleton_method(:column_names) { @columns }
    klass.define_singleton_method(:records) { @records }
    klass.define_singleton_method(:create!) do |attrs|
      @records << attrs
      Struct.new(*attrs.keys).new(*attrs.values)
    end
    klass.define_singleton_method(:reset!) { @records = [] }
    klass
  end

  # ── install ──────────────────────────────────────────────────────────────────

  describe ".install" do
    it "extends ClassMethods onto the operation class" do
      model = fake_model
      op    = make_op { def call; end }
      op.plugin(Easyop::Plugins::Recording, model: model)
      expect(op.singleton_class.ancestors).to include(Easyop::Plugins::Recording::ClassMethods)
    end

    it "prepends RunWrapper onto the operation class" do
      model = fake_model
      op    = make_op { def call; end }
      op.plugin(Easyop::Plugins::Recording, model: model)
      expect(op.ancestors).to include(Easyop::Plugins::Recording::RunWrapper)
    end
  end

  # ── successful recording ─────────────────────────────────────────────────────

  describe "recording a successful call" do
    let(:model) { fake_model }

    let(:op) do
      m = model
      make_op { def call; ctx.output = "ok"; end }.tap do |klass|
        stub_const("RecordingSuccessOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
    end

    before { op.call(input: "data") }

    it "calls model.create! once" do
      expect(model.records.length).to eq(1)
    end

    it "records operation_name as the class name" do
      expect(model.records.first[:operation_name]).to eq("RecordingSuccessOp")
    end

    it "records success: true" do
      expect(model.records.first[:success]).to be true
    end

    it "records a non-negative duration_ms" do
      expect(model.records.first[:duration_ms]).to be_a(Float)
      expect(model.records.first[:duration_ms]).to be >= 0
    end

    it "records performed_at" do
      expect(model.records.first[:performed_at]).not_to be_nil
    end
  end

  # ── failed recording ─────────────────────────────────────────────────────────

  describe "recording a failed call" do
    let(:model) { fake_model }

    let(:op) do
      m = model
      make_op { def call; ctx.fail!(error: "went wrong"); end }.tap do |klass|
        stub_const("RecordingFailOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
    end

    before { op.call }

    it "records success: false" do
      expect(model.records.first[:success]).to be false
    end

    it "records the error message" do
      expect(model.records.first[:error_message]).to eq("went wrong")
    end
  end

  # ── recording false ──────────────────────────────────────────────────────────

  describe "recording false on a class" do
    let(:model) { fake_model }

    it "skips model.create!" do
      m   = model
      op  = make_op { def call; end }.tap do |klass|
        stub_const("RecordingDisabledOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.recording false
      end
      op.call
      expect(model.records).to be_empty
    end
  end

  # ── inheritance of recording flag ────────────────────────────────────────────

  describe "recording inheritance" do
    let(:model) { fake_model }

    let(:parent_op) do
      m = model
      make_op { def call; end }.tap do |klass|
        stub_const("RecordingParentOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
    end

    it "subclass with recording false does not record" do
      child = Class.new(parent_op) do
        recording false
        def call; end
      end
      stub_const("RecordingChildNoOp", child)
      child.call
      expect(model.records).to be_empty
    end

    it "parent still records when subclass has recording false" do
      _child = Class.new(parent_op) do
        recording false
        def call; end
      end
      parent_op.call
      expect(model.records.length).to eq(1)
    end

    it "subclass can re-enable recording when parent has recording false" do
      m = model
      base = make_op { def call; end }.tap do |klass|
        stub_const("RecordingBaseDisabled", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.recording false
      end

      child = Class.new(base) do
        recording true
        def call; end
      end
      stub_const("RecordingChildEnabled", child)
      child.call
      expect(model.records.length).to eq(1)
    end

    it "subclass inherits _recording_model from parent" do
      child = Class.new(parent_op) { def call; end }
      expect(child._recording_model).to eq(model)
    end
  end

  # ── record_params option ─────────────────────────────────────────────────────

  describe "record_params option" do
    it "writes params_data when record_params: true (default)" do
      m  = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsTrueOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_params: true)
      end
      op.call(name: "Alice")
      expect(m.records.first.key?(:params_data)).to be true
    end

    it "does not write params_data when record_params: false" do
      m  = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsFalseOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_params: false)
      end
      op.call(name: "Alice")
      expect(m.records.first.key?(:params_data)).to be false
    end
  end

  # ── SCRUBBED_KEYS ────────────────────────────────────────────────────────────

  describe "params_data scrubbing" do
    let(:model) { fake_model }

    let(:op) do
      m = model
      make_op { def call; end }.tap do |klass|
        stub_const("RecordingScrubOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
    end

    let(:params_data) do
      op.call(
        name: "Bob",
        password: "secret123",
        token: "tok_abc",
        secret: "shh",
        api_key: "key123",
        password_confirmation: "secret123"
      )
      JSON.parse(model.records.first[:params_data])
    end

    it "excludes :password from params_data" do
      expect(params_data).not_to have_key("password")
    end

    it "excludes :token from params_data" do
      expect(params_data).not_to have_key("token")
    end

    it "excludes :secret from params_data" do
      expect(params_data).not_to have_key("secret")
    end

    it "excludes :api_key from params_data" do
      expect(params_data).not_to have_key("api_key")
    end

    it "excludes :password_confirmation from params_data" do
      expect(params_data).not_to have_key("password_confirmation")
    end

    it "keeps non-scrubbed keys in params_data" do
      expect(params_data["name"]).to eq("Bob")
    end
  end

  # ── ActiveRecord objects in ctx ──────────────────────────────────────────────

  describe "ActiveRecord objects are serialized in params_data" do
    let(:model) { fake_model }

    it "serializes AR objects as { id:, class: } hash" do
      fake_ar_class = Class.new(ActiveRecord::Base) do
        def self.name; "FakeUser"; end
        attr_reader :id
        def initialize(id); @id = id; end
      end

      user = fake_ar_class.new(99)

      m  = model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordingArOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end

      op.call(user: user)
      data = JSON.parse(m.records.first[:params_data])
      expect(data["user"]).to eq("id" => 99, "class" => "FakeUser")
    end
  end

  # ── missing columns ──────────────────────────────────────────────────────────

  describe "model missing a column" do
    it "silently skips columns not in column_names" do
      m  = fake_model(columns: %w[operation_name success])
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordingSlimOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call
      record = m.records.first
      expect(record.keys.map(&:to_s).sort).to eq(%w[operation_name success])
    end
  end

  # ── model.create! raises ─────────────────────────────────────────────────────

  describe "when model.create! raises" do
    it "the operation still succeeds" do
      m = fake_model
      m.define_singleton_method(:create!) { |_attrs| raise "DB error" }
      op = make_op { def call; ctx.output = "ok"; end }.tap do |klass|
        stub_const("RecordingRaiseOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      result = op.call
      expect(result.success?).to be true
    end
  end

  # ── anonymous classes (no name) ──────────────────────────────────────────────

  describe "anonymous operation class" do
    it "skips recording when class has no name" do
      m  = fake_model
      op = make_op { def call; end }
      op.plugin(Easyop::Plugins::Recording, model: m)
      op.call
      expect(m.records).to be_empty
    end
  end

  # ── _recording_enabled? default (no @_recording_enabled set, no superclass) ──

  describe "_recording_enabled? on a class without explicit recording setting" do
    it "defaults to true when no flag is set and superclass does not respond to _recording_enabled?" do
      m  = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordingDefaultEnabledOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      # No call to klass.recording(...) — should default to true
      expect(op._recording_enabled?).to be true
    end
  end

  # ── _recording_record_params? default (no superclass) ────────────────────────

  describe "_recording_record_params? on a fresh class" do
    it "defaults to true when no @_recording_record_params is set and no superclass responds" do
      # Build a raw module that includes ClassMethods without going through plugin
      klass = Class.new
      klass.extend(Easyop::Plugins::Recording::ClassMethods)
      # No @_recording_record_params set, superclass is Object (does not respond)
      expect(klass._recording_record_params?).to be true
    end
  end

  # ── _recording_safe_params rescue ────────────────────────────────────────────

  describe "_recording_safe_params silently returns nil on error" do
    it "returns nil and does not raise when ctx.to_h raises during serialization" do
      m = fake_model

      op = make_op do
        def call
          ctx.ok = true
        end
      end.tap do |klass|
        stub_const("RecordingBadSerializeOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end

      # Directly test _recording_safe_params via a wrapper operation instance
      instance = op.new
      ctx_obj = Easyop::Ctx.new(ok: true)
      instance.instance_variable_set(:@ctx, ctx_obj)

      # Stub ctx.to_h to return an object whose .except raises
      bad_hash = double("bad_hash")
      allow(bad_hash).to receive(:except).and_raise(StandardError, "serialization error")
      allow(ctx_obj).to receive(:to_h).and_return(bad_hash)

      # _recording_safe_params should rescue and return nil
      result = instance.send(:_recording_safe_params, ctx_obj)
      expect(result).to be_nil
    end
  end

  # ── _recording_warn with Rails logger ─────────────────────────────────────────

  describe "_recording_warn logs to Rails.logger when defined" do
    it "logs a warning when model.create! raises and Rails.logger is available" do
      m = fake_model
      m.define_singleton_method(:create!) { |_attrs| raise "DB write failed" }

      fake_logger = double("logger", warn: nil)
      stub_const("Rails", Module.new do
        def self.respond_to?(meth, *args)
          meth == :logger ? true : super
        end
        define_singleton_method(:logger) { fake_logger }
      end)

      op = make_op { def call; ctx.output = "ok"; end }.tap do |klass|
        stub_const("RecordingWarnRailsOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end

      op.call
      expect(fake_logger).to have_received(:warn).with(/EasyOp::Recording/)
    end
  end

  # ── flow tracing ──────────────────────────────────────────────────────────────

  TRACING_COLUMNS = %w[
    operation_name success error_message params_data duration_ms performed_at
    root_reference_id reference_id parent_operation_name parent_reference_id
  ].freeze

  def tracing_model
    fake_model(columns: TRACING_COLUMNS)
  end

  describe "flow tracing — standalone operation" do
    let(:model) { tracing_model }

    before do
      m = model
      op = make_op { def call; end }.tap do |klass|
        stub_const("TracingStandaloneOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call(name: "Alice")
    end

    let(:record) { model.records.first }

    it "generates a root_reference_id" do
      expect(record[:root_reference_id]).to be_a(String).and match(/\A[0-9a-f-]{36}\z/)
    end

    it "generates a reference_id distinct from root_reference_id" do
      expect(record[:reference_id]).to be_a(String).and match(/\A[0-9a-f-]{36}\z/)
    end

    it "has nil parent_operation_name" do
      expect(record[:parent_operation_name]).to be_nil
    end

    it "has nil parent_reference_id" do
      expect(record[:parent_reference_id]).to be_nil
    end
  end

  describe "flow tracing — simple flow with two steps" do
    let(:model) { tracing_model }

    before do
      require "easyop/flow"
      m = model

      step_a = make_op { def call; end }.tap do |k|
        stub_const("TracingFlowStepA", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      step_b = make_op { def call; end }.tap do |k|
        stub_const("TracingFlowStepB", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      flow = Class.new do
        include Easyop::Flow
        flow step_a, step_b
      end.tap do |k|
        stub_const("TracingSimpleFlow", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      flow.call
    end

    let(:flow_record)   { model.records.find { |r| r[:operation_name] == "TracingSimpleFlow" } }
    let(:step_a_record) { model.records.find { |r| r[:operation_name] == "TracingFlowStepA" } }
    let(:step_b_record) { model.records.find { |r| r[:operation_name] == "TracingFlowStepB" } }

    it "records all three executions" do
      expect(model.records.length).to eq(3)
    end

    it "all records share the same root_reference_id" do
      ids = model.records.map { |r| r[:root_reference_id] }.uniq
      expect(ids.length).to eq(1)
      expect(ids.first).not_to be_nil
    end

    it "flow has nil parent fields (it is the root)" do
      expect(flow_record[:parent_operation_name]).to be_nil
      expect(flow_record[:parent_reference_id]).to be_nil
    end

    it "step A has the flow as its parent" do
      expect(step_a_record[:parent_operation_name]).to eq("TracingSimpleFlow")
      expect(step_a_record[:parent_reference_id]).to eq(flow_record[:reference_id])
    end

    it "step B has the flow as its parent (not step A)" do
      expect(step_b_record[:parent_operation_name]).to eq("TracingSimpleFlow")
      expect(step_b_record[:parent_reference_id]).to eq(flow_record[:reference_id])
    end

    it "each record has a distinct reference_id" do
      ids = model.records.map { |r| r[:reference_id] }
      expect(ids.uniq.length).to eq(3)
    end
  end

  describe "flow tracing — nested flows (3 levels)" do
    let(:model) { tracing_model }

    before do
      require "easyop/flow"
      m = model

      leaf = make_op { def call; end }.tap do |k|
        stub_const("TracingLeafOp", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      inner = Class.new do
        include Easyop::Flow
        flow leaf
      end.tap do |k|
        stub_const("TracingInnerFlow", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      outer = Class.new do
        include Easyop::Flow
        flow inner
      end.tap do |k|
        stub_const("TracingOuterFlow", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      outer.call
    end

    let(:outer_record) { model.records.find { |r| r[:operation_name] == "TracingOuterFlow" } }
    let(:inner_record) { model.records.find { |r| r[:operation_name] == "TracingInnerFlow" } }
    let(:leaf_record)  { model.records.find { |r| r[:operation_name] == "TracingLeafOp" } }

    it "all three share the same root_reference_id" do
      ids = model.records.map { |r| r[:root_reference_id] }.uniq
      expect(ids.length).to eq(1)
      expect(ids.first).not_to be_nil
    end

    it "outer has no parent" do
      expect(outer_record[:parent_operation_name]).to be_nil
      expect(outer_record[:parent_reference_id]).to be_nil
    end

    it "inner's parent is outer" do
      expect(inner_record[:parent_operation_name]).to eq("TracingOuterFlow")
      expect(inner_record[:parent_reference_id]).to eq(outer_record[:reference_id])
    end

    it "leaf's parent is inner" do
      expect(leaf_record[:parent_operation_name]).to eq("TracingInnerFlow")
      expect(leaf_record[:parent_reference_id]).to eq(inner_record[:reference_id])
    end
  end

  describe "flow tracing — parent has recording false" do
    let(:model) { tracing_model }

    before do
      require "easyop/flow"
      m = model

      child = make_op { def call; end }.tap do |k|
        stub_const("TracingChildEnabled", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      parent_flow = Class.new do
        include Easyop::Flow
        flow child
      end.tap do |k|
        stub_const("TracingParentDisabled", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
        k.recording false
      end

      parent_flow.call
    end

    let(:record) { model.records.first }

    it "only the child is recorded" do
      expect(model.records.length).to eq(1)
      expect(record[:operation_name]).to eq("TracingChildEnabled")
    end

    it "child acts as its own root (parent skipped tracing setup)" do
      expect(record[:root_reference_id]).not_to be_nil
      expect(record[:parent_operation_name]).to be_nil
      expect(record[:parent_reference_id]).to be_nil
    end
  end

  describe "flow tracing — internal ctx keys excluded from params_data" do
    let(:model) { tracing_model }

    it "does not leak __recording_* keys into params_data JSON" do
      m  = model
      op = make_op { def call; end }.tap do |klass|
        stub_const("TracingParamsOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call(name: "test")

      data = JSON.parse(model.records.first[:params_data])
      expect(data.keys).to all(satisfy { |k| !k.start_with?("__recording_") })
    end
  end

  describe "flow tracing — bare Flow class (Recording not installed on the flow)" do
    # When include Easyop::Flow is used without inheriting from a recorded base
    # class, CallBehavior#call now forwards the parent tracing ctx so steps still
    # see the flow as their parent.  The flow itself is NOT written to the model
    # (Recording is not installed on it), but steps carry the correct parent info.
    let(:model) { tracing_model }

    before do
      require "easyop/flow"
      m = model

      step_a = make_op { def call; end }.tap do |k|
        stub_const("BareFlowStepA", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      step_b = make_op { def call; end }.tap do |k|
        stub_const("BareFlowStepB", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end

      # Bare Flow — no plugin Recording installed on it
      bare_flow = Class.new do
        include Easyop::Flow
        flow step_a, step_b
      end
      stub_const("BareFlowClass", bare_flow)

      bare_flow.call
    end

    it "records only the step operations (not the flow itself)" do
      expect(model.records.length).to eq(2)
      expect(model.records.map { |r| r[:operation_name] }).to contain_exactly(
        "BareFlowStepA", "BareFlowStepB"
      )
    end

    it "all step records share the same root_reference_id" do
      ids = model.records.map { |r| r[:root_reference_id] }.uniq
      expect(ids.length).to eq(1)
      expect(ids.first).to be_a(String).and match(/\A[0-9a-f-]{36}\z/)
    end

    it "step A carries the bare flow as parent_operation_name" do
      rec = model.records.find { |r| r[:operation_name] == "BareFlowStepA" }
      expect(rec[:parent_operation_name]).to eq("BareFlowClass")
    end

    it "step B carries the bare flow as parent_operation_name" do
      rec = model.records.find { |r| r[:operation_name] == "BareFlowStepB" }
      expect(rec[:parent_operation_name]).to eq("BareFlowClass")
    end

    it "both steps share the same parent_reference_id (flow's synthetic uuid)" do
      parent_ids = model.records.map { |r| r[:parent_reference_id] }.uniq
      expect(parent_ids.length).to eq(1)
      expect(parent_ids.first).to be_a(String).and match(/\A[0-9a-f-]{36}\z/)
    end

    it "both steps are siblings (distinct reference_ids)" do
      ids = model.records.map { |r| r[:reference_id] }
      expect(ids.uniq.length).to eq(2)
    end
  end

  describe "flow tracing — column filtering still works" do
    it "silently drops tracing columns when model lacks them" do
      m  = fake_model(columns: %w[operation_name success])
      op = make_op { def call; end }.tap do |klass|
        stub_const("TracingSlimModelOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call
      expect(m.records.first.keys.map(&:to_s).sort).to eq(%w[operation_name success])
    end
  end

  # ── record_result ─────────────────────────────────────────────────────────────

  ALL_COLUMNS = (TRACING_COLUMNS + %w[result_data]).freeze

  def result_model
    fake_model(columns: ALL_COLUMNS)
  end

  describe "record_result — attrs form (single key)" do
    it "persists the specified ctx key as JSON in result_data" do
      m = result_model
      op = make_op { def call; ctx.info = "hello"; end }.tap do |klass|
        stub_const("RecordResultAttrsOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result attrs: :info
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("info" => "hello")
    end
  end

  describe "record_result — attrs form (multiple keys)" do
    it "persists all specified ctx keys as JSON" do
      m = result_model
      op = make_op { def call; ctx.info = "a"; ctx.status = "b"; end }.tap do |klass|
        stub_const("RecordResultMultiOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result attrs: [:info, :status]
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("info" => "a", "status" => "b")
    end
  end

  describe "record_result — block form" do
    it "calls the block with ctx and persists the returned hash" do
      m = result_model
      op = make_op { def call; ctx.total = 42; end }.tap do |klass|
        stub_const("RecordResultBlockOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result { |c| { computed: c.total * 2 } }
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("computed" => 84)
    end
  end

  describe "record_result — symbol form (private instance method)" do
    it "calls the named method on the operation instance" do
      m = result_model
      op = make_op do
        def call
          ctx.info = "from method"
        end

        private

        def build_result
          { info: ctx.info }
        end
      end.tap do |klass|
        stub_const("RecordResultSymbolOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result :build_result
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("info" => "from method")
    end
  end

  describe "record_result — plugin-level default via install" do
    it "persists result_data when configured at the plugin level" do
      m = result_model
      op = make_op { def call; ctx.metadata = "meta-value"; end }.tap do |klass|
        stub_const("RecordResultPluginLevelOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_result: { attrs: :metadata })
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("metadata" => "meta-value")
    end
  end

  describe "record_result — class-level overrides plugin-level default" do
    it "uses the class-level config instead of the plugin-level one" do
      m = result_model
      op = make_op { def call; ctx.info = "class"; ctx.metadata = "plugin"; end }.tap do |klass|
        stub_const("RecordResultOverrideOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_result: { attrs: :metadata })
        klass.record_result attrs: :info
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("info" => "class")
      expect(data).not_to have_key("metadata")
    end
  end

  describe "record_result — missing ctx key" do
    it "stores nil for a key that was never set in ctx" do
      m = result_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordResultMissingKeyOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result attrs: :nonexistent
      end
      op.call
      data = JSON.parse(m.records.first[:result_data])
      expect(data).to eq("nonexistent" => nil)
    end
  end

  describe "record_result — not configured" do
    it "does not add result_data key to the record" do
      m = result_model
      op = make_op { def call; ctx.info = "x"; end }.tap do |klass|
        stub_const("RecordResultNoneOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        # No record_result configured
      end
      op.call
      expect(m.records.first.key?(:result_data)).to be false
    end
  end

  describe "record_result — model lacks result_data column" do
    it "silently skips result_data when the column is absent" do
      m = fake_model  # default columns — no result_data
      op = make_op { def call; ctx.info = "x"; end }.tap do |klass|
        stub_const("RecordResultNoColOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result attrs: :info
      end
      expect { op.call }.not_to raise_error
      expect(m.records.first.key?(:result_data)).to be false
    end
  end

  describe "record_result — AR objects in result serialized as {id:, class:}" do
    it "serializes ActiveRecord objects the same way as params_data" do
      fake_ar_class = Class.new(ActiveRecord::Base) do
        def self.name; "FakeProduct"; end
        attr_reader :id
        def initialize(id); @id = id; end
      end
      product = fake_ar_class.new(7)

      m = result_model
      op = make_op { def call; ctx.product = ctx[:_product_ref]; end }.tap do |klass|
        stub_const("RecordResultArOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result attrs: :product
      end
      op.call(_product_ref: product)
      data = JSON.parse(m.records.first[:result_data])
      expect(data["product"]).to eq("id" => 7, "class" => "FakeProduct")
    end
  end

  describe "record_result — serialization error is swallowed" do
    it "stores nil and the operation still succeeds when the block raises" do
      m = result_model
      op = make_op { def call; ctx.info = "ok"; end }.tap do |klass|
        stub_const("RecordResultRaiseOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result { |_c| raise "boom" }
      end
      result = op.call
      expect(result.success?).to be true
      expect(m.records.first[:result_data]).to be_nil
    end
  end

  describe "record_result — child inherits parent's config" do
    it "records result_data on a subclass that does not re-declare record_result" do
      m = result_model
      parent = make_op { def call; ctx.info = "inherited"; end }.tap do |klass|
        stub_const("RecordResultParentOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result attrs: :info
      end
      child = Class.new(parent) do
        def call; ctx.info = "child-value"; end
      end
      stub_const("RecordResultChildOp", child)
      child.call
      data = JSON.parse(m.records.last[:result_data])
      expect(data).to eq("info" => "child-value")
    end
  end
end
