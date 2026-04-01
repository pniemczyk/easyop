require "spec_helper"

RSpec.describe Easyop::Hooks do
  let(:log) { [] }

  def make_op(&blk)
    l = log
    Class.new do
      include Easyop::Operation
      define_method(:log) { l }
      class_eval(&blk) if blk
    end
  end

  # ── before ────────────────────────────────────────────────────────────────────

  describe "before hooks" do
    it "runs before call" do
      op = make_op do
        before { log << :before }
        def call; log << :call; end
      end
      op.call
      expect(log).to eq([:before, :call])
    end

    it "runs multiple before hooks in order" do
      op = make_op do
        before { log << 1 }
        before { log << 2 }
        def call; log << 3; end
      end
      op.call
      expect(log).to eq([1, 2, 3])
    end

    it "supports method name" do
      op = make_op do
        before :setup
        def call;  log << :call;  end
        def setup; log << :setup; end
      end
      op.call
      expect(log).to eq([:setup, :call])
    end

    it "can fail! in a before hook" do
      op = make_op do
        before { ctx.fail!(error: "pre-fail") }
        def call; log << :should_not_run; end
      end
      result = op.call
      expect(result.failure?).to be true
      expect(log).to be_empty
    end
  end

  # ── after ─────────────────────────────────────────────────────────────────────

  describe "after hooks" do
    it "runs after call" do
      op = make_op do
        after { log << :after }
        def call; log << :call; end
      end
      op.call
      expect(log).to eq([:call, :after])
    end

    it "runs after hook even when call fails via fail!" do
      op = make_op do
        after { log << :after }
        def call
          log << :call
          ctx.fail!
        end
      end
      op.call
      expect(log).to eq([:call, :after])
    end

    it "runs multiple after hooks in order" do
      op = make_op do
        after { log << 1 }
        after { log << 2 }
        def call; end
      end
      op.call
      expect(log).to eq([1, 2])
    end
  end

  # ── around ────────────────────────────────────────────────────────────────────

  describe "around hooks" do
    it "wraps call with a block hook" do
      op = make_op do
        around do |inner|
          log << :around_start
          inner.call
          log << :around_end
        end
        def call; log << :call; end
      end
      op.call
      expect(log).to eq([:around_start, :call, :around_end])
    end

    it "wraps call with a method hook" do
      op = make_op do
        around :with_wrap
        def call; log << :call; end
        def with_wrap
          log << :wrap_start
          yield
          log << :wrap_end
        end
      end
      op.call
      expect(log).to eq([:wrap_start, :call, :wrap_end])
    end

    it "nests multiple around hooks (first-defined outermost)" do
      op = make_op do
        around { |inner| log << :a1; inner.call; log << :a2 }
        around { |inner| log << :b1; inner.call; log << :b2 }
        def call; log << :call; end
      end
      op.call
      expect(log).to eq([:a1, :b1, :call, :b2, :a2])
    end

    it "around wraps the before/after hooks too" do
      op = make_op do
        around { |inner| log << :around_open; inner.call; log << :around_close }
        before { log << :before }
        after  { log << :after }
        def call; log << :call; end
      end
      op.call
      expect(log).to eq([:around_open, :before, :call, :after, :around_close])
    end
  end

  # ── inheritance ───────────────────────────────────────────────────────────────

  describe "hook inheritance" do
    it "subclass inherits parent hooks" do
      parent = make_op { before { log << :parent_before } }
      child  = Class.new(parent) do
        before { log.push(:child_before) }
        def call; log.push(:call); end
      end
      child.call
      expect(log).to eq([:parent_before, :child_before, :call])
    end

    it "parent hooks are not affected by subclass additions" do
      parent = make_op { before { log << :parent_before }; def call; log << :parent_call; end }
      child  = Class.new(parent) { before { log << :child_before } }
      parent.call
      expect(log).to eq([:parent_before, :parent_call])
    end
  end
end
