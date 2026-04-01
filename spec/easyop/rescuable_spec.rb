require "spec_helper"

RSpec.describe Easyop::Rescuable do
  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      class_eval(&blk) if blk
    end
  end

  # ── Basic rescue_from ─────────────────────────────────────────────────────────

  describe "rescue_from with: method" do
    let(:op) do
      make_op do
        rescue_from ArgumentError, with: :handle_arg_error

        def call
          raise ArgumentError, "bad arg"
        end

        def handle_arg_error(e)
          ctx.fail!(error: "Handled: #{e.message}")
        end
      end
    end

    it "calls the named handler" do
      result = op.call
      expect(result.failure?).to be true
      expect(result.error).to eq("Handled: bad arg")
    end
  end

  describe "rescue_from with block" do
    let(:op) do
      make_op do
        rescue_from TypeError do |e|
          ctx.fail!(error: "type error: #{e.message}")
        end

        def call
          raise TypeError, "wrong type"
        end
      end
    end

    it "executes the block" do
      result = op.call
      expect(result.error).to eq("type error: wrong type")
    end
  end

  # ── Multiple exception classes ────────────────────────────────────────────────

  describe "multiple exception classes in one rescue_from" do
    let(:op) do
      make_op do
        rescue_from ArgumentError, TypeError, with: :handle_bad

        def handle_bad(e)
          ctx.fail!(error: e.class.name)
        end
      end
    end

    it "handles ArgumentError" do
      child = Class.new(op) { def call; raise ArgumentError; end }
      expect(child.call.error).to eq("ArgumentError")
    end

    it "handles TypeError" do
      child = Class.new(op) { def call; raise TypeError; end }
      expect(child.call.error).to eq("TypeError")
    end
  end

  # ── Subclass matching ─────────────────────────────────────────────────────────

  describe "subclass exception matching" do
    it "matches parent exception class" do
      op = make_op do
        rescue_from StandardError, with: :handle_std
        def call; raise RuntimeError, "runtime boom"; end
        def handle_std(e); ctx.fail!(error: "std: #{e.message}"); end
      end
      expect(op.call.error).to eq("std: runtime boom")
    end
  end

  # ── First-match wins ──────────────────────────────────────────────────────────

  describe "first-defined handler wins" do
    it "uses the first matching handler" do
      op = make_op do
        rescue_from StandardError do |_e|
          ctx.fail!(error: "standard")
        end
        rescue_from RuntimeError do |_e|
          ctx.fail!(error: "runtime")
        end

        def call; raise RuntimeError, "boom"; end
      end
      # RuntimeError is a StandardError subclass; first handler (StandardError) matches first
      result = op.call
      expect(result.error).to eq("standard")
    end
  end

  # ── Unhandled exceptions ──────────────────────────────────────────────────────

  describe "unhandled exception" do
    it "re-raises if no matching handler" do
      op = make_op do
        rescue_from ArgumentError, with: :handle
        def call; raise TypeError, "unhandled"; end
        def handle(e); ctx.fail!; end
      end
      expect { op.call }.to raise_error(TypeError)
    end
  end

  # ── Inheritance ───────────────────────────────────────────────────────────────

  describe "inheritance" do
    it "inherits parent rescue handlers" do
      parent = make_op do
        rescue_from RuntimeError do |e|
          ctx.fail!(error: "parent: #{e.message}")
        end
      end

      child = Class.new(parent) do
        def call; raise RuntimeError, "from child"; end
      end

      result = child.call
      expect(result.error).to eq("parent: from child")
    end

    it "child handlers take priority over parent" do
      parent = make_op do
        rescue_from RuntimeError, with: :parent_handle
        def parent_handle(_e); ctx.fail!(error: "parent"); end
      end

      child = Class.new(parent) do
        rescue_from RuntimeError, with: :child_handle
        def call; raise RuntimeError; end
        def child_handle(_e); ctx.fail!(error: "child"); end
      end

      expect(child.call.error).to eq("child")
    end
  end

  # ── Validation ────────────────────────────────────────────────────────────────

  describe "argument validation" do
    it "raises ArgumentError without with: or block" do
      expect do
        Class.new { include Easyop::Operation }.rescue_from(StandardError)
      end.to raise_error(ArgumentError, /with:.*block/)
    end
  end

  # ── String-based exception class name ────────────────────────────────────────

  describe "rescue_from with a string class name" do
    it "resolves the string to a constant and matches exceptions" do
      op = make_op do
        rescue_from "ArgumentError" do |e|
          ctx.fail!(error: "string-rescued: #{e.message}")
        end
        def call
          raise ArgumentError, "string class"
        end
      end
      result = op.call
      expect(result.failure?).to be true
      expect(result.error).to eq("string-rescued: string class")
    end
  end

  # ── NameError when constant not loaded ────────────────────────────────────────

  describe "rescue_from with an unresolvable string constant" do
    it "skips the handler and falls through when the constant is not loaded" do
      op = make_op do
        rescue_from "NonExistentError::ThatDoesNotExist" do |_e|
          ctx.fail!(error: "should not reach here")
        end
        rescue_from ArgumentError do |e|
          ctx.fail!(error: "fallthrough: #{e.message}")
        end
        def call
          raise ArgumentError, "unresolvable"
        end
      end
      result = op.call
      expect(result.failure?).to be true
      expect(result.error).to eq("fallthrough: unresolvable")
    end
  end
end
