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
end
