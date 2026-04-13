# Minimal ActiveJob::Base stub — no gem required
module ActiveJob
  class Base
    def self.queue_as(_queue); end

    def self.enqueued_jobs
      @enqueued_jobs ||= []
    end

    def self.set(**options)
      JobBuilder.new(self, options)
    end

    def self.perform_later(*args)
      enqueued_jobs << { job: self, args: args, options: {} }
    end

    def self.reset!
      @enqueued_jobs = []
    end
  end

  class JobBuilder
    def initialize(job_class, options)
      @job_class = job_class
      @options   = options
    end

    def set(**more_options)
      @options.merge!(more_options)
      self
    end

    def perform_later(*args)
      @job_class.enqueued_jobs << { job: @job_class, args: args, options: @options }
    end
  end
end

require "spec_helper"
require "easyop/plugins/async"

RSpec.describe Easyop::Plugins::Async do
  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      class_eval(&blk) if blk
    end
  end

  # The job class is built lazily and stores enqueued jobs on the Job subclass.
  # Fetch it (creating if necessary) and reset between tests.
  def job_class
    Easyop::Plugins::Async.job_class
  end

  def enqueued_jobs
    job_class.enqueued_jobs
  end

  before do
    # Eagerly create job class so its enqueued_jobs can be reset
    job_class.reset!
  end

  after do
    Easyop::Plugins::Async.instance_variable_set(:@job_class, nil)
    Easyop::Plugins::Async.send(:remove_const, :Job) if Easyop::Plugins::Async.const_defined?(:Job)
  rescue NameError
    # already removed
  end

  # ── install ──────────────────────────────────────────────────────────────────

  describe ".install" do
    it "adds call_async class method to the operation" do
      op = make_op { def call; end }
      op.plugin(Easyop::Plugins::Async)
      expect(op).to respond_to(:call_async)
    end
  end

  # ── call_async enqueues a job ─────────────────────────────────────────────────

  describe ".call_async" do
    let(:op) do
      make_op { def call; end }.tap do |klass|
        stub_const("AsyncEnqueueOp", klass)
        klass.plugin(Easyop::Plugins::Async)
      end
    end

    it "calls perform_later with the operation class name and serialized attrs" do
      op.call_async(value: "hello")
      entry = enqueued_jobs.last
      expect(entry[:args][0]).to eq("AsyncEnqueueOp")
      expect(entry[:args][1]).to include("value" => "hello")
    end

    it "uses the default queue 'default' when no queue specified in plugin" do
      op.call_async
      entry = enqueued_jobs.last
      expect(entry[:options][:queue]).to eq("default")
    end

    it "uses the custom queue specified in the plugin install options" do
      custom_op = make_op { def call; end }.tap do |klass|
        stub_const("AsyncCustomQueueOp", klass)
        klass.plugin(Easyop::Plugins::Async, queue: "priority")
      end
      custom_op.call_async
      entry = enqueued_jobs.last
      expect(entry[:options][:queue]).to eq("priority")
    end

    it "overrides queue per call_async invocation" do
      op.call_async(queue: "low")
      entry = enqueued_jobs.last
      expect(entry[:options][:queue]).to eq("low")
    end

    it "passes wait: option to .set" do
      op.call_async(wait: 300)
      entry = enqueued_jobs.last
      expect(entry[:options][:wait]).to eq(300)
    end

    it "passes wait_until: option to .set" do
      future = Time.now + 3600
      op.call_async(wait_until: future)
      entry = enqueued_jobs.last
      expect(entry[:options][:wait_until]).to eq(future)
    end

    it "passes plain string/integer attrs through as-is" do
      op.call_async(name: "Alice", count: 5)
      attrs = enqueued_jobs.last[:args][1]
      expect(attrs["name"]).to eq("Alice")
      expect(attrs["count"]).to eq(5)
    end
  end

  # ── AR serialization ──────────────────────────────────────────────────────────

  describe "ActiveRecord object serialization" do
    it "serializes AR objects as __ar_class / __ar_id" do
      # Build a fake AR class/instance that inherits from the stub
      unless defined?(ActiveRecord)
        stub_const("ActiveRecord::Base", Class.new)
      end

      fake_ar_class = Class.new(ActiveRecord::Base) do
        def self.name; "FakeProduct"; end
        attr_reader :id
        def initialize(id); @id = id; end
      end

      fake_ar_instance = fake_ar_class.new(7)

      op = make_op { def call; end }.tap do |klass|
        stub_const("AsyncArOp", klass)
        klass.plugin(Easyop::Plugins::Async)
      end

      op.call_async(product: fake_ar_instance)
      attrs = enqueued_jobs.last[:args][1]
      expect(attrs["product"]).to eq("__ar_class" => "FakeProduct", "__ar_id" => 7)
    end
  end

  # ── .queue DSL ────────────────────────────────────────────────────────────────

  describe ".queue" do
    it "overrides the plugin-level default queue on the class itself" do
      op = make_op { def call; end }.tap do |klass|
        stub_const("AsyncQueueDslOp", klass)
        klass.plugin(Easyop::Plugins::Async, queue: "default")
        klass.queue(:priority)
      end
      op.call_async
      expect(enqueued_jobs.last[:options][:queue]).to eq("priority")
    end

    it "accepts a string queue name" do
      op = make_op { def call; end }.tap do |klass|
        stub_const("AsyncQueueStringOp", klass)
        klass.plugin(Easyop::Plugins::Async)
        klass.queue("critical")
      end
      expect(op._async_default_queue).to eq("critical")
    end

    it "is inherited by subclasses" do
      parent = make_op { def call; end }.tap do |klass|
        stub_const("AsyncQueueParentOp", klass)
        klass.plugin(Easyop::Plugins::Async)
        klass.queue(:weather)
      end
      child = Class.new(parent) { def call; end }
      stub_const("AsyncQueueChildOp", child)
      expect(child._async_default_queue).to eq("weather")
    end

    it "can be overridden again in a subclass" do
      parent = make_op { def call; end }.tap do |klass|
        stub_const("AsyncQueueOverrideParent", klass)
        klass.plugin(Easyop::Plugins::Async)
        klass.queue(:weather)
      end
      child = Class.new(parent) do
        def call; end
        queue :notifications
      end
      stub_const("AsyncQueueOverrideChild", child)
      expect(child._async_default_queue).to eq("notifications")
      expect(parent._async_default_queue).to eq("weather")
    end
  end

  # ── _async_default_queue inheritance ──────────────────────────────────────────

  describe "_async_default_queue inheritance" do
    it "subclass inherits parent default queue" do
      parent = make_op { def call; end }.tap do |klass|
        stub_const("AsyncParentOp", klass)
        klass.plugin(Easyop::Plugins::Async, queue: "inherited_q")
      end
      child = Class.new(parent) { def call; end }
      stub_const("AsyncChildOp", child)
      expect(child._async_default_queue).to eq("inherited_q")
    end
  end

  # ── ActiveJob not defined ─────────────────────────────────────────────────────

  describe "when ActiveJob is not available" do
    it "raises LoadError from call_async" do
      op = make_op { def call; end }.tap do |klass|
        stub_const("AsyncNoJobOp", klass)
        klass.plugin(Easyop::Plugins::Async)
      end

      hide_const("ActiveJob")
      expect { op.call_async }.to raise_error(LoadError, /ActiveJob/)
    end
  end

  # ── job_class ─────────────────────────────────────────────────────────────────

  describe ".job_class" do
    it "returns a class named Easyop::Plugins::Async::Job" do
      expect(job_class.name).to eq("Easyop::Plugins::Async::Job")
    end
  end

  # ── Job#perform ───────────────────────────────────────────────────────────────

  describe "Job#perform" do
    # constantize is an ActiveSupport String extension — stub it for these tests
    before do
      unless String.method_defined?(:constantize)
        String.class_eval do
          def constantize
            Object.const_get(self)
          end
        end
      end
    end

    it "deserializes plain attrs and calls the operation" do
      log = []
      op_class = Class.new do
        include Easyop::Operation
        define_method(:call) { log << ctx[:value] }
      end
      stub_const("TestAsyncOp", op_class)

      job = job_class.new
      job.perform("TestAsyncOp", { "value" => "hello" })
      expect(log).to eq(["hello"])
    end

    it "re-fetches AR objects via ClassName.find(id)" do
      fetched = []
      fake_ar_class = Class.new do
        def self.name; "AsyncFakeUser"; end
        define_singleton_method(:find) { |id| fetched << id; "user_#{id}" }
      end
      stub_const("AsyncFakeUser", fake_ar_class)

      log = []
      op_class = Class.new do
        include Easyop::Operation
        define_method(:call) { log << ctx[:user] }
      end
      stub_const("TestAsyncArOp", op_class)

      job = job_class.new
      job.perform("TestAsyncArOp", { "user" => { "__ar_class" => "AsyncFakeUser", "__ar_id" => 42 } })

      expect(fetched).to eq([42])
      expect(log).to eq(["user_42"])
    end
  end
end
