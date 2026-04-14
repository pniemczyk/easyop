require "spec_helper"

RSpec.describe Easyop::Schema do
  after(:each) { Easyop.reset_config! }

  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      class_eval(&blk) if blk
    end
  end

  # ── required params ───────────────────────────────────────────────────────────

  describe "required params" do

    let(:op) do
      make_op do
        params do
          required :email,  String
          required :amount, Integer
        end
        def call; ctx.ok = true; end
      end
    end

    it "passes when all required params present and correct type" do
      result = op.call(email: "a@b.com", amount: 10)
      expect(result.success?).to be true
    end

    it "fails when required param is missing" do
      result = op.call(email: "a@b.com")
      expect(result.failure?).to be true
      expect(result.error).to include("amount")
    end

    it "fails when required param is wrong type" do
      Easyop.configure { |c| c.strict_types = true }
      result = op.call(email: "a@b.com", amount: "ten")
      expect(result.failure?).to be true
      expect(result.error).to include("amount")
    end

    it "warns (not raises) on type mismatch when strict_types is false" do
      expect do
        op.call(email: "a@b.com", amount: "ten")
      end.to output(/Type mismatch/).to_stderr
    end
  end

  # ── optional params with defaults ─────────────────────────────────────────────

  describe "optional params" do
    let(:op) do
      make_op do
        params do
          required :name,   String
          optional :active, :boolean, default: true
          optional :role,   String,   default: "user"
        end
        def call; end
      end
    end

    it "uses default when optional param is absent" do
      result = op.call(name: "Alice")
      expect(result.active).to be true
      expect(result.role).to   eq("user")
    end

    it "uses provided value over default" do
      result = op.call(name: "Alice", active: false, role: "admin")
      expect(result.active).to be false
      expect(result.role).to   eq("admin")
    end

    it "does not fail when optional param is missing" do
      result = op.call(name: "Alice")
      expect(result.success?).to be true
    end
  end

  # ── result schema ─────────────────────────────────────────────────────────────

  describe "result schema" do
    context "with strict_types" do
      before { Easyop.configure { |c| c.strict_types = true } }

      let(:op) do
        make_op do
          result do
            required :record, Hash
          end
          def call
            ctx.record = ctx.value
          end
        end
      end

      it "passes when result type is correct" do
        result = op.call(value: { id: 1 })
        expect(result.success?).to be true
      end

      it "fails when result type is wrong" do
        result = op.call(value: "not a hash")
        expect(result.failure?).to be true
        expect(result.error).to include("record")
      end

      it "skips result validation on failure" do
        op2 = make_op do
          result { required :record, Hash }
          def call
            ctx.fail!(error: "early fail")
          end
        end
        result = op2.call
        expect(result.error).to eq("early fail")
      end
    end
  end

  # ── type symbols ──────────────────────────────────────────────────────────────

  describe "type symbol shorthands" do
    it "resolves :boolean to TrueClass | FalseClass" do
      Easyop.configure { |c| c.strict_types = true }
      op = make_op do
        params { required :flag, :boolean }
        def call; end
      end
      expect(op.call(flag: true).success?).to  be true
      expect(op.call(flag: false).success?).to be true
      expect(op.call(flag: "yes").failure?).to be true
    end

    it "resolves :string to String" do
      Easyop.configure { |c| c.strict_types = true }
      op = make_op do
        params { required :name, :string }
        def call; end
      end
      expect(op.call(name: "Alice").success?).to be true
      expect(op.call(name: 42).failure?).to      be true
    end
  end

  # ── unknown type symbol ───────────────────────────────────────────────────────

  describe "unknown type symbol" do
    it "raises ArgumentError at class definition time" do
      expect do
        Class.new do
          include Easyop::Operation
          params { required :x, :unknown_type }
        end
      end.to raise_error(ArgumentError, /Unknown type/)
    end
  end

  # ── inputs / outputs aliases ──────────────────────────────────────────────────

  describe "inputs / outputs aliases" do
    it "accepts inputs as alias for params" do
      op = make_op do
        inputs { required :name, String }
        def call; end
      end
      expect(op.call(name: "Alice").success?).to be true
    end

    it "accepts outputs as alias for result" do
      op = make_op do
        outputs { required :name, String }
        def call; ctx.name = ctx.value; end
      end
      expect(op.call(value: "Alice").success?).to be true
    end
  end

  # ── FieldSchema#fields ────────────────────────────────────────────────────────

  describe "FieldSchema#fields" do
    it "returns a copy of defined fields" do
      schema = Easyop::FieldSchema.new
      schema.required(:email, String)
      schema.optional(:role, String, default: "user")
      fields = schema.fields
      expect(fields.length).to eq(2)
      expect(fields.map(&:name)).to eq([:email, :role])
    end

    it "returns a dup so modifying it does not affect the schema" do
      schema = Easyop::FieldSchema.new
      schema.required(:name, String)
      original_count = schema.fields.length
      schema.fields << :extra
      expect(schema.fields.length).to eq(original_count)
    end
  end

  # ── Easyop.configure and reset_config! ───────────────────────────────────────

  describe "Easyop configuration" do
    after { Easyop.reset_config! }

    it "Easyop.configure yields the config object" do
      Easyop.configure do |c|
        c.strict_types = true
      end
      expect(Easyop.config.strict_types).to be true
    end

    it "Easyop.config returns the same object on repeated calls" do
      first  = Easyop.config
      second = Easyop.config
      expect(first).to be(second)
    end

    it "Easyop.reset_config! creates a fresh config" do
      Easyop.configure { |c| c.strict_types = true }
      Easyop.reset_config!
      expect(Easyop.config.strict_types).to be false
    end

    it "strict_types defaults to false" do
      expect(Easyop.config.strict_types).to be false
    end

    it "type_adapter defaults to :native" do
      expect(Easyop.config.type_adapter).to eq(:native)
    end
  end
end
