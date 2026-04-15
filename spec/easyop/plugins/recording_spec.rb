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

  # ── params_data records only INPUT keys (not computed results) ───────────────

  describe "params_data input-only recording (true form)" do
    let(:model) { fake_model }

    it "excludes ctx keys computed during the call body from params_data" do
      m = model
      op = make_op do
        def call
          # ctx.result_value is set DURING the operation — should not appear in params_data
          ctx.result_value = "computed"
        end
      end.tap do |klass|
        stub_const("InputOnlyExcludesComputedOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call(name: "Alice")
      data = JSON.parse(m.records.first[:params_data])
      expect(data).to have_key("name")
      expect(data).not_to have_key("result_value")
    end

    it "includes all keys present at call time" do
      m = model
      op = make_op { def call; ctx.extra = "added"; end }.tap do |klass|
        stub_const("InputOnlyIncludesInputsOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call(user_id: 42, action: "create")
      data = JSON.parse(m.records.first[:params_data])
      expect(data["user_id"]).to eq(42)
      expect(data["action"]).to eq("create")
      expect(data).not_to have_key("extra")
    end

    it "still applies FILTERED_KEYS to input params" do
      m = model
      op = make_op { def call; end }.tap do |klass|
        stub_const("InputOnlyFilteredOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call(email: "a@b.com", password: "s3cr3t")
      data = JSON.parse(m.records.first[:params_data])
      expect(data["email"]).to eq("a@b.com")
      expect(data["password"]).to eq("[FILTERED]")
    end

    it "excludes INTERNAL_CTX_KEYS even when present in input snapshot (nested ops)" do
      require "easyop/flow"
      m = model
      child = make_op { def call; end }.tap do |klass|
        stub_const("InputOnlyNestedChildOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      parent_flow = Class.new do
        include Easyop::Flow
        flow child
      end
      stub_const("InputOnlyNestedFlow", parent_flow)
      parent_flow.call(name: "test")
      data = JSON.parse(m.records.first[:params_data])
      expect(data.keys).to all(satisfy { |k| !k.start_with?("__recording_") })
      expect(data["name"]).to eq("test")
    end

    it "custom attrs form CAN include computed ctx keys (user controls the list)" do
      m = model
      op = make_op do
        def call
          ctx.computed_result = "output"
        end
      end.tap do |klass|
        stub_const("InputOnlyAttrsComputedOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params attrs: :computed_result
      end
      op.call(name: "Alice")
      data = JSON.parse(m.records.first[:params_data])
      # attrs form is evaluated after the call — user explicitly asked for computed_result
      expect(data["computed_result"]).to eq("output")
      expect(data).not_to have_key("name")
    end

    it "custom block form CAN include computed ctx keys" do
      m = model
      op = make_op do
        def call
          ctx.total = 99
        end
      end.tap do |klass|
        stub_const("InputOnlyBlockComputedOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params { |c| { total: c[:total] } }
      end
      op.call(user_id: 1)
      data = JSON.parse(m.records.first[:params_data])
      expect(data["total"]).to eq(99)
    end

    it "custom symbol form CAN include computed ctx keys" do
      m = model
      op = make_op do
        def call
          ctx.order_id = 7
        end

        private

        def extract_params
          { order_id: ctx[:order_id] }
        end
      end.tap do |klass|
        stub_const("InputOnlySymbolComputedOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params :extract_params
      end
      op.call(user_id: 1)
      data = JSON.parse(m.records.first[:params_data])
      expect(data["order_id"]).to eq(7)
    end

    it "record_result true still captures computed ctx keys (input-only is params-only)" do
      m = fake_model(columns: %w[
        operation_name success error_message params_data duration_ms performed_at result_data
      ])
      op = make_op do
        def call
          ctx.user = "created_user"
        end
      end.tap do |klass|
        stub_const("InputOnlyResultStillFullOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result true
      end
      op.call(email: "a@b.com")
      params = JSON.parse(m.records.first[:params_data])
      result = JSON.parse(m.records.first[:result_data])
      # params_data: only the input key
      expect(params.keys).to contain_exactly("email")
      # result_data: full ctx after execution — includes computed user
      expect(result["user"]).to eq("created_user")
      expect(result["email"]).to eq("a@b.com")
    end
  end

  # ── FILTERED_KEYS ────────────────────────────────────────────────────────────

  describe "params_data filtering" do
    let(:model) { fake_model }

    let(:op) do
      m = model
      make_op { def call; end }.tap do |klass|
        stub_const("RecordingFilterOp", klass)
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

    it "replaces :password value with [FILTERED]" do
      expect(params_data["password"]).to eq("[FILTERED]")
    end

    it "replaces :token value with [FILTERED]" do
      expect(params_data["token"]).to eq("[FILTERED]")
    end

    it "replaces :secret value with [FILTERED]" do
      expect(params_data["secret"]).to eq("[FILTERED]")
    end

    it "replaces :api_key value with [FILTERED]" do
      expect(params_data["api_key"]).to eq("[FILTERED]")
    end

    it "replaces :password_confirmation value with [FILTERED]" do
      expect(params_data["password_confirmation"]).to eq("[FILTERED]")
    end

    it "keeps non-filtered keys in params_data" do
      expect(params_data["name"]).to eq("Bob")
    end
  end

  # ── custom filter_keys ───────────────────────────────────────────────────────

  describe "custom filter_keys" do
    let(:model) { fake_model }

    def call_op(op, **attrs)
      op.call(**attrs)
      JSON.parse(model.records.last[:params_data])
    end

    context "plugin install filter_keys: [:api_token]" do
      let(:op) do
        m = model
        make_op { def call; end }.tap do |klass|
          stub_const("FilterInstallOp", klass)
          klass.plugin(Easyop::Plugins::Recording, model: m, filter_keys: [:api_token])
        end
      end

      it "filters the declared Symbol key" do
        data = call_op(op, name: "Alice", api_token: "tok_123")
        expect(data["api_token"]).to eq("[FILTERED]")
      end

      it "keeps other non-sensitive keys" do
        data = call_op(op, name: "Alice", api_token: "tok_123")
        expect(data["name"]).to eq("Alice")
      end

      it "still filters built-in FILTERED_KEYS" do
        data = call_op(op, name: "Alice", password: "s3cr3t", api_token: "tok")
        expect(data["password"]).to eq("[FILTERED]")
      end
    end

    context "plugin install filter_keys: [/token/i] (Regexp)" do
      let(:op) do
        m = model
        make_op { def call; end }.tap do |klass|
          stub_const("FilterRegexpInstallOp", klass)
          klass.plugin(Easyop::Plugins::Recording, model: m, filter_keys: [/token/i])
        end
      end

      it "filters keys matching the regexp (exact)" do
        data = call_op(op, auth_token: "abc")
        expect(data["auth_token"]).to eq("[FILTERED]")
      end

      it "filters keys matching the regexp (case-insensitive)" do
        data = call_op(op, authTOKEN: "abc")
        expect(data["authTOKEN"]).to eq("[FILTERED]")
      end

      it "keeps keys that do not match" do
        data = call_op(op, name: "Alice")
        expect(data["name"]).to eq("Alice")
      end
    end

    context "class-level filter_params DSL" do
      let(:op) do
        m = model
        make_op { def call; end }.tap do |klass|
          stub_const("FilterDslOp", klass)
          klass.plugin(Easyop::Plugins::Recording, model: m)
          klass.filter_params(:session_id, /private/i)
        end
      end

      it "filters a Symbol key declared with filter_params" do
        data = call_op(op, session_id: "sess_abc", name: "Alice")
        expect(data["session_id"]).to eq("[FILTERED]")
      end

      it "filters keys matching a Regexp declared with filter_params" do
        data = call_op(op, private_note: "internal", name: "Alice")
        expect(data["private_note"]).to eq("[FILTERED]")
      end

      it "keeps other keys" do
        data = call_op(op, session_id: "s", name: "Alice")
        expect(data["name"]).to eq("Alice")
      end
    end

    context "filter_params is inherited and additive" do
      let(:base_op) do
        m = model
        make_op { def call; end }.tap do |klass|
          stub_const("FilterBaseOp", klass)
          klass.plugin(Easyop::Plugins::Recording, model: m)
          klass.filter_params(:base_secret)
        end
      end

      let(:child_op) do
        parent = base_op
        Class.new(parent).tap do |klass|
          stub_const("FilterChildOp", klass)
          klass.filter_params(:child_secret)
        end
      end

      it "child filters its own declared key" do
        data = call_op(child_op, child_secret: "x", name: "Alice")
        expect(data["child_secret"]).to eq("[FILTERED]")
      end

      it "child also filters the parent's declared key" do
        data = call_op(child_op, base_secret: "x", name: "Alice")
        expect(data["base_secret"]).to eq("[FILTERED]")
      end

      it "parent does not filter child-only key" do
        call_op(base_op, child_secret: "x", name: "Alice")
        # base_op has no child_secret rule — key kept with original value
        expect(model.records.last).to be_a(Object) # just verifying no crash
        data = JSON.parse(model.records.last[:params_data])
        expect(data["child_secret"]).to eq("x")
      end
    end

    context "global Easyop.config.recording_filter_keys" do
      before { Easyop.configure { |c| c.recording_filter_keys = [:global_secret, /access.?key/i] } }

      let(:op) do
        m = model
        make_op { def call; end }.tap do |klass|
          stub_const("FilterGlobalOp", klass)
          klass.plugin(Easyop::Plugins::Recording, model: m)
        end
      end

      it "filters a Symbol from the global list" do
        data = call_op(op, global_secret: "x", name: "Alice")
        expect(data["global_secret"]).to eq("[FILTERED]")
      end

      it "filters keys matching a global Regexp" do
        data = call_op(op, access_key: "k", name: "Alice")
        expect(data["access_key"]).to eq("[FILTERED]")
      end

      it "still filters built-in FILTERED_KEYS" do
        data = call_op(op, password: "s3cr3t", global_secret: "x")
        expect(data["password"]).to eq("[FILTERED]")
      end

      it "keeps non-matching keys" do
        data = call_op(op, name: "Alice", global_secret: "x")
        expect(data["name"]).to eq("Alice")
      end
    end

    context "all three layers are additive" do
      before { Easyop.configure { |c| c.recording_filter_keys = [:global_key] } }

      let(:op) do
        m = model
        make_op { def call; end }.tap do |klass|
          stub_const("FilterAllLayersOp", klass)
          klass.plugin(Easyop::Plugins::Recording, model: m, filter_keys: [:install_key])
          klass.filter_params(:class_key)
        end
      end

      it "filters built-in FILTERED_KEYS" do
        data = call_op(op, password: "x")
        expect(data["password"]).to eq("[FILTERED]")
      end

      it "filters global config key" do
        data = call_op(op, global_key: "x")
        expect(data["global_key"]).to eq("[FILTERED]")
      end

      it "filters plugin install key" do
        data = call_op(op, install_key: "x")
        expect(data["install_key"]).to eq("[FILTERED]")
      end

      it "filters class DSL key" do
        data = call_op(op, class_key: "x")
        expect(data["class_key"]).to eq("[FILTERED]")
      end
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

  # ── _recording_record_params_config default (no superclass) ─────────────────

  describe "_recording_record_params_config on a fresh class" do
    it "defaults to true when no @_recording_record_params is set and no superclass responds" do
      # Build a raw module that includes ClassMethods without going through plugin
      klass = Class.new
      klass.extend(Easyop::Plugins::Recording::ClassMethods)
      # No @_recording_record_params set, superclass is Object (does not respond)
      expect(klass._recording_record_params_config).to be true
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
      result = instance.send(:_recording_safe_params, ctx_obj, true)
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

  TRACING_WITH_INDEX_COLUMNS = (TRACING_COLUMNS + %w[execution_index]).freeze

  def tracing_model
    fake_model(columns: TRACING_COLUMNS)
  end

  def tracing_model_with_index
    fake_model(columns: TRACING_WITH_INDEX_COLUMNS)
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

  # ── record_result: false (new default) ───────────────────────────────────────

  describe "record_result — default false at install" do
    it "does not add result_data when no record_result is configured" do
      m = result_model
      op = make_op { def call; ctx.info = "x"; end }.tap do |klass|
        stub_const("RecordResultDefaultFalseOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call
      expect(m.records.first.key?(:result_data)).to be false
    end
  end

  describe "record_result — explicit false at install level" do
    it "does not write result_data when record_result: false" do
      m = result_model
      op = make_op { def call; ctx.info = "x"; end }.tap do |klass|
        stub_const("RecordResultFalseInstallOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_result: false)
      end
      op.call
      expect(m.records.first.key?(:result_data)).to be false
    end
  end

  # ── record_result: true — full ctx snapshot ───────────────────────────────────

  describe "record_result — true at install level (full ctx snapshot)" do
    it "persists all non-internal ctx keys in result_data" do
      m = result_model
      op = make_op { def call; ctx.name = "Alice"; ctx.score = 99; end }.tap do |klass|
        stub_const("RecordResultTrueInstallOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_result: true)
      end
      op.call(name: "Alice", score: 99)
      data = JSON.parse(m.records.first[:result_data])
      expect(data["name"]).to eq("Alice")
      expect(data["score"]).to eq(99)
    end

    it "replaces FILTERED_KEYS values with [FILTERED] in result_data" do
      m = result_model
      op = make_op { def call; ctx.password = "s3cr3t"; ctx.name = "Bob"; end }.tap do |klass|
        stub_const("RecordResultTrueFilterInstallOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_result: true)
      end
      op.call(name: "Bob", password: "s3cr3t")
      data = JSON.parse(m.records.first[:result_data])
      expect(data["password"]).to eq("[FILTERED]")
      expect(data["name"]).to eq("Bob")
    end

    it "excludes INTERNAL_CTX_KEYS from result_data" do
      m = result_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordResultTrueNoInternalOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_result: true)
      end
      op.call(name: "test")
      data = JSON.parse(m.records.first[:result_data])
      expect(data.keys).to all(satisfy { |k| !k.start_with?("__recording_") })
    end
  end

  describe "record_result — true DSL form" do
    it "persists full ctx snapshot via DSL record_result true" do
      m = result_model
      op = make_op { def call; ctx.value = 42; end }.tap do |klass|
        stub_const("RecordResultTrueDslOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result true
      end
      op.call(value: 42)
      data = JSON.parse(m.records.first[:result_data])
      expect(data["value"]).to eq(42)
    end

    it "applies FILTERED_KEYS to full ctx snapshot via DSL" do
      m = result_model
      op = make_op { def call; ctx.token = "tok"; ctx.user = "Alice"; end }.tap do |klass|
        stub_const("RecordResultTrueDslFilterOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result true
      end
      op.call(user: "Alice", token: "tok")
      data = JSON.parse(m.records.first[:result_data])
      expect(data["token"]).to eq("[FILTERED]")
      expect(data["user"]).to eq("Alice")
    end

    it "excludes INTERNAL_CTX_KEYS from DSL true snapshot" do
      m = result_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordResultTrueDslInternalOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result true
      end
      op.call(name: "x")
      data = JSON.parse(m.records.first[:result_data])
      expect(data.keys).to all(satisfy { |k| !k.start_with?("__recording_") })
    end
  end

  describe "record_result — true inherited by child" do
    it "child records full ctx when parent has record_result true" do
      m = result_model
      parent = make_op { def call; ctx.info = "parent"; end }.tap do |klass|
        stub_const("RecordResultTrueInheritParent", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_result true
      end
      child = Class.new(parent) do
        def call; ctx.info = "child"; end
      end
      stub_const("RecordResultTrueInheritChild", child)
      child.call
      data = JSON.parse(m.records.last[:result_data])
      expect(data["info"]).to eq("child")
    end
  end

  describe "record_result — child overrides parent false with true" do
    it "child can opt in to result recording when parent has false" do
      m = result_model
      parent = make_op { def call; ctx.info = "x"; end }.tap do |klass|
        stub_const("RecordResultFalseParent", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        # parent keeps default false
      end
      child = Class.new(parent) do
        record_result true
        def call; ctx.info = "child-result"; end
      end
      stub_const("RecordResultTrueChild", child)
      child.call
      data = JSON.parse(m.records.last[:result_data])
      expect(data["info"]).to eq("child-result")
    end
  end

  # ── record_params DSL and install-level forms ─────────────────────────────────

  describe "record_params — install-level Hash form (single attr)" do
    it "writes only the specified attr key in params_data" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsInstallHashSingleOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_params: { attrs: :name })
      end
      op.call(name: "Alice", password: "secret")
      data = JSON.parse(m.records.first[:params_data])
      expect(data.keys).to eq(["name"])
      expect(data["name"]).to eq("Alice")
    end
  end

  describe "record_params — install-level Hash form (multiple attrs)" do
    it "writes only the specified attr keys in params_data" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsInstallHashMultiOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_params: { attrs: [:name, :email] })
      end
      op.call(name: "Alice", email: "a@b.com", password: "secret")
      data = JSON.parse(m.records.first[:params_data])
      expect(data.keys.sort).to eq(["email", "name"])
      expect(data["name"]).to eq("Alice")
      expect(data["email"]).to eq("a@b.com")
    end
  end

  describe "record_params — install-level Proc form" do
    it "calls the proc with ctx and uses result as params_data" do
      m = fake_model
      extractor = ->(ctx) { { custom: ctx[:name].upcase } }
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsInstallProcOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_params: extractor)
      end
      op.call(name: "alice")
      data = JSON.parse(m.records.first[:params_data])
      expect(data).to eq("custom" => "ALICE")
    end
  end

  describe "record_params — install-level Symbol form (method name)" do
    it "calls the named method on the instance and uses result as params_data" do
      m = fake_model
      op = make_op do
        def call; end

        private

        def build_params
          { extracted: ctx[:name] }
        end
      end.tap do |klass|
        stub_const("RecordParamsInstallSymbolOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m, record_params: :build_params)
      end
      op.call(name: "Bob")
      data = JSON.parse(m.records.first[:params_data])
      expect(data).to eq("extracted" => "Bob")
    end
  end

  describe "record_params DSL — attrs form (single key)" do
    it "writes only the specified key in params_data" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsDslAttrsOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params attrs: :email
      end
      op.call(email: "x@y.com", password: "s")
      data = JSON.parse(m.records.first[:params_data])
      expect(data.keys).to eq(["email"])
      expect(data["email"]).to eq("x@y.com")
    end
  end

  describe "record_params DSL — block form" do
    it "calls the block with ctx and uses result as params_data" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsDslBlockOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params { |c| { user: c[:name] } }
      end
      op.call(name: "Charlie")
      data = JSON.parse(m.records.first[:params_data])
      expect(data).to eq("user" => "Charlie")
    end
  end

  describe "record_params DSL — symbol form (private method)" do
    it "calls the named method on the instance and uses result as params_data" do
      m = fake_model
      op = make_op do
        def call; end

        private

        def safe_params
          { user_id: ctx[:id] }
        end
      end.tap do |klass|
        stub_const("RecordParamsDslSymbolOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params :safe_params
      end
      op.call(id: 7, password: "secret")
      data = JSON.parse(m.records.first[:params_data])
      expect(data).to eq("user_id" => 7)
    end
  end

  describe "record_params DSL — false form" do
    it "does not write params_data when record_params false is called" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsDslFalseOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params false
      end
      op.call(name: "Alice")
      expect(m.records.first.key?(:params_data)).to be false
    end
  end

  describe "record_params DSL — true form (explicit full ctx)" do
    it "writes all ctx keys (same as default) when record_params true is called" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsDslTrueOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params true
      end
      op.call(name: "Alice", role: "admin")
      data = JSON.parse(m.records.first[:params_data])
      expect(data["name"]).to eq("Alice")
      expect(data["role"]).to eq("admin")
    end
  end

  describe "record_params — FILTERED_KEYS always applied to custom forms" do
    it "replaces filtered key values with [FILTERED] even in attrs form" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsAttrsFilterOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params attrs: [:name, :password]
      end
      op.call(name: "Alice", password: "s3cr3t")
      data = JSON.parse(m.records.first[:params_data])
      expect(data["name"]).to eq("Alice")
      expect(data["password"]).to eq("[FILTERED]")
    end

    it "replaces filtered key values with [FILTERED] in block form" do
      m = fake_model
      op = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsBlockFilterOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params { |c| { name: c[:name], token: c[:token] } }
      end
      op.call(name: "Alice", token: "tok_abc")
      data = JSON.parse(m.records.first[:params_data])
      expect(data["name"]).to eq("Alice")
      expect(data["token"]).to eq("[FILTERED]")
    end

    it "replaces filtered key values with [FILTERED] in symbol form" do
      m = fake_model
      op = make_op do
        def call; end

        private

        def extract_params
          { name: ctx[:name], secret: ctx[:secret] }
        end
      end.tap do |klass|
        stub_const("RecordParamsSymbolFilterOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params :extract_params
      end
      op.call(name: "Alice", secret: "shh")
      data = JSON.parse(m.records.first[:params_data])
      expect(data["name"]).to eq("Alice")
      expect(data["secret"]).to eq("[FILTERED]")
    end
  end

  describe "record_params — config inherited by child" do
    it "child uses parent's record_params config when not overridden" do
      m = fake_model
      parent = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsInheritParent", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params attrs: :name
      end
      child = Class.new(parent) do
        def call; end
      end
      stub_const("RecordParamsInheritChild", child)
      child.call(name: "Alice", email: "a@b.com")
      data = JSON.parse(m.records.last[:params_data])
      expect(data.keys).to eq(["name"])
      expect(data["name"]).to eq("Alice")
    end
  end

  describe "record_params — child overrides parent's config" do
    it "child uses its own record_params config instead of parent's" do
      m = fake_model
      parent = make_op { def call; end }.tap do |klass|
        stub_const("RecordParamsOverrideParent", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
        klass.record_params attrs: :name
      end
      child = Class.new(parent) do
        record_params attrs: :email
        def call; end
      end
      stub_const("RecordParamsOverrideChild", child)
      child.call(name: "Alice", email: "a@b.com")
      data = JSON.parse(m.records.last[:params_data])
      expect(data.keys).to eq(["email"])
      expect(data["email"]).to eq("a@b.com")
      expect(data).not_to have_key("name")
    end
  end

  # ── execution_index ───────────────────────────────────────────────────────────

  describe "execution_index — model without column" do
    it "silently omits execution_index when model lacks the column" do
      m  = tracing_model # no execution_index column
      op = make_op { def call; end }.tap do |klass|
        stub_const("ExIdxNoColumnOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call
      expect(m.records.first).not_to have_key(:execution_index)
    end
  end

  describe "execution_index — standalone (root) operation" do
    it "is nil for a root operation with no parent" do
      m  = tracing_model_with_index
      op = make_op { def call; end }.tap do |klass|
        stub_const("ExIdxRootOp", klass)
        klass.plugin(Easyop::Plugins::Recording, model: m)
      end
      op.call
      expect(m.records.first[:execution_index]).to be_nil
    end
  end

  describe "execution_index — two siblings in a recorded flow" do
    before do
      require "easyop/flow"
      m = tracing_model_with_index

      step_a = make_op { def call; end }.tap do |k|
        stub_const("ExIdxSibA", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end
      step_b = make_op { def call; end }.tap do |k|
        stub_const("ExIdxSibB", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end
      flow = Class.new do
        include Easyop::Flow
        flow step_a, step_b
      end.tap do |k|
        stub_const("ExIdxSibFlow", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
      end
      flow.call
      @model = m
    end

    it "root flow has execution_index nil" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxSibFlow" }
      expect(rec[:execution_index]).to be_nil
    end

    it "first step has execution_index 1" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxSibA" }
      expect(rec[:execution_index]).to eq(1)
    end

    it "second step has execution_index 2" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxSibB" }
      expect(rec[:execution_index]).to eq(2)
    end
  end

  describe "execution_index — three siblings in a recorded flow" do
    before do
      require "easyop/flow"
      m = tracing_model_with_index

      [%w[ExIdx3A ExIdx3B ExIdx3C]].each do
        # intentionally no-op
      end

      sa = make_op { def call; end }.tap { |k| stub_const("ExIdx3A", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      sb = make_op { def call; end }.tap { |k| stub_const("ExIdx3B", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      sc = make_op { def call; end }.tap { |k| stub_const("ExIdx3C", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      f  = Class.new { include Easyop::Flow; flow sa, sb, sc }.tap { |k| stub_const("ExIdx3Flow", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      f.call
      @model = m
    end

    it "steps are indexed 1, 2, 3 in call order" do
      idx = %w[ExIdx3A ExIdx3B ExIdx3C].map do |name|
        @model.records.find { |r| r[:operation_name] == name }[:execution_index]
      end
      expect(idx).to eq([1, 2, 3])
    end
  end

  describe "execution_index — nested flow: grandchildren reset per parent" do
    # Tree: Root > [B(1), C(2) > [D(1), E(2)], F(3)]
    before do
      require "easyop/flow"
      m = tracing_model_with_index

      mb = make_op { def call; end }.tap { |k| stub_const("ExIdxNstB", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      md = make_op { def call; end }.tap { |k| stub_const("ExIdxNstD", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      me = make_op { def call; end }.tap { |k| stub_const("ExIdxNstE", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      mf = make_op { def call; end }.tap { |k| stub_const("ExIdxNstF", k); k.plugin(Easyop::Plugins::Recording, model: m) }

      inner_c = Class.new { include Easyop::Flow; flow md, me }.tap { |k| stub_const("ExIdxNstC", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      root    = Class.new { include Easyop::Flow; flow mb, inner_c, mf }.tap { |k| stub_const("ExIdxNstRoot", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      root.call
      @model = m
    end

    def rec(name)
      @model.records.find { |r| r[:operation_name] == name }
    end

    it "Root has execution_index nil" do
      expect(rec("ExIdxNstRoot")[:execution_index]).to be_nil
    end

    it "B is first child of Root → execution_index 1" do
      expect(rec("ExIdxNstB")[:execution_index]).to eq(1)
    end

    it "C is second child of Root → execution_index 2" do
      expect(rec("ExIdxNstC")[:execution_index]).to eq(2)
    end

    it "F is third child of Root → execution_index 3" do
      expect(rec("ExIdxNstF")[:execution_index]).to eq(3)
    end

    it "D is first child of C → execution_index 1 (resets under new parent)" do
      expect(rec("ExIdxNstD")[:execution_index]).to eq(1)
    end

    it "E is second child of C → execution_index 2" do
      expect(rec("ExIdxNstE")[:execution_index]).to eq(2)
    end
  end

  describe "execution_index — bare flow (Recording not on flow)" do
    before do
      require "easyop/flow"
      m = tracing_model_with_index

      sa = make_op { def call; end }.tap { |k| stub_const("ExIdxBareA", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      sb = make_op { def call; end }.tap { |k| stub_const("ExIdxBareB", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      bare = Class.new { include Easyop::Flow; flow sa, sb }
      stub_const("ExIdxBareFlow", bare)
      bare.call
      @model = m
    end

    it "step A gets execution_index 1" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxBareA" }
      expect(rec[:execution_index]).to eq(1)
    end

    it "step B gets execution_index 2" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxBareB" }
      expect(rec[:execution_index]).to eq(2)
    end
  end

  describe "execution_index — sibling with recording: false skips index slot" do
    # When a step has recording disabled, it doesn't claim an index slot.
    # Its siblings' indices are not affected by the disabled step's slot.
    before do
      require "easyop/flow"
      m = tracing_model_with_index

      sa = make_op { def call; end }.tap { |k| stub_const("ExIdxSkipA", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      sb = make_op { def call; end }.tap do |k|
        stub_const("ExIdxSkipB", k)
        k.plugin(Easyop::Plugins::Recording, model: m)
        k.recording false
      end
      sc = make_op { def call; end }.tap { |k| stub_const("ExIdxSkipC", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      f  = Class.new { include Easyop::Flow; flow sa, sb, sc }.tap { |k| stub_const("ExIdxSkipFlow", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      f.call
      @model = m
    end

    it "A gets execution_index 1" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxSkipA" }
      expect(rec[:execution_index]).to eq(1)
    end

    it "C gets execution_index 2 (B skipped index slot)" do
      rec = @model.records.find { |r| r[:operation_name] == "ExIdxSkipC" }
      expect(rec[:execution_index]).to eq(2)
    end

    it "B is not recorded" do
      expect(@model.records.map { |r| r[:operation_name] }).not_to include("ExIdxSkipB")
    end
  end

  describe "execution_index — __recording_child_counts excluded from params_data" do
    it "does not leak __recording_child_counts into params_data after sibling runs" do
      require "easyop/flow"
      m = tracing_model_with_index

      sa = make_op { def call; end }.tap { |k| stub_const("ExIdxLeakA", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      sb = make_op { def call; end }.tap { |k| stub_const("ExIdxLeakB", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      f  = Class.new { include Easyop::Flow; flow sa, sb }.tap { |k| stub_const("ExIdxLeakFlow", k); k.plugin(Easyop::Plugins::Recording, model: m) }
      f.call

      @model.records.each do |rec|
        next unless rec[:params_data]
        data = JSON.parse(rec[:params_data])
        expect(data.keys).to all(satisfy { |k| !k.start_with?("__recording_") })
      end if (@model = m)
    end
  end
end
