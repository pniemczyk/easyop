# frozen_string_literal: true

# Shared in-memory stubs and base test class for tests that exercise
# Easyop::PersistentFlow / durable-flow machinery without a real database.
#
# Require this file (after test_helper) in any test file that needs
# FakeFlowRun, FakeFlowRunStep, FakeScheduledTask, or PersistentFlowTestBase.

module PersistentFlowTestStubs
  class FakeFlowRunScope
    include Enumerable

    def initialize(records)
      @records = records
    end

    def each(&blk) = @records.each(&blk)
    def count      = @records.size
    def exists?    = @records.any?

    def where(*args, **conditions)
      return self if args.any? && conditions.empty?   # skip string-pattern clauses (LIKE, jsonb)

      FakeFlowRunScope.new(@records.select do |r|
        conditions.all? { |k, v| r.public_send(k) == v }
      end)
    end
  end

  class FakeFlowRunStepScope
    include Enumerable

    def initialize(records)
      @records = records
    end

    def each(&blk) = @records.each(&blk)
    def count      = @records.size
    def exists?    = @records.any?

    def where(*args, **conditions)
      return self if args.any? && conditions.empty?

      FakeFlowRunStepScope.new(@records.select do |r|
        conditions.all? { |k, v| r.public_send(k) == v }
      end)
    end
  end

  # Minimal AR-like FlowRun stub
  class FakeFlowRun
    include Easyop::PersistentFlow::FlowRunModel

    attr_accessor :id, :flow_class, :context_data, :status, :current_step_index,
                  :subject_type, :subject_id, :started_at, :finished_at, :tags

    @@store = []
    @@next_id = 1

    def self.store = @@store
    def self.reset! = (@@store = []; @@next_id = 1)

    def self.create!(attrs)
      obj = new
      attrs.each { |k, v| obj.public_send(:"#{k}=", v) }
      obj.id = @@next_id
      @@next_id += 1
      @@store << obj
      obj
    end

    def self.find(id)
      @@store.find { |r| r.id == id } or raise "FakeFlowRun #{id} not found"
    end

    def self.where(*args, **conditions)
      return FakeFlowRunScope.new(@@store) if args.any? && conditions.empty?

      FakeFlowRunScope.new(@@store.select do |r|
        conditions.all? { |k, v| r.public_send(k) == v }
      end)
    end

    def initialize
      @status             = 'pending'
      @current_step_index = 0
      @context_data       = '{}'
    end

    def update!(attrs)
      attrs.each { |k, v| public_send(:"#{k}=", v) }
      self
    end

    def update_columns(attrs)
      attrs.each { |k, v| public_send(:"#{k}=", v) }
      self
    end

    def reload = self  # in-memory: nothing to reload

    def terminal?
      Easyop::PersistentFlow::FlowRunModel::TERMINAL_STATUSES.include?(status)
    end
  end

  # Minimal AR-like FlowRunStep stub
  class FakeFlowRunStep
    include Easyop::PersistentFlow::FlowRunStepModel

    attr_accessor :id, :flow_run_id, :step_index, :operation_class, :status,
                  :attempt, :error_class, :error_message, :started_at, :finished_at

    @@store = []
    @@next_id = 1

    def self.store = @@store
    def self.reset! = (@@store = []; @@next_id = 1)

    def self.create!(attrs)
      obj = new
      attrs.each { |k, v| obj.public_send(:"#{k}=", v) }
      obj.id = @@next_id
      @@next_id += 1
      @@store << obj
      obj
    end

    def self.find(id)
      @@store.find { |r| r.id == id } or raise "FakeFlowRunStep #{id} not found"
    end

    def self.where(*args, **conditions)
      return FakeFlowRunStepScope.new(@@store) if args.any? && conditions.empty?

      FakeFlowRunStepScope.new(@@store.select do |r|
        conditions.all? { |k, v| r.public_send(k) == v }
      end)
    end

    def initialize
      @status  = 'running'
      @attempt = 0
    end

    def update_columns(attrs)
      attrs.each { |k, v| public_send(:"#{k}=", v) }
      self
    end
  end

  # Minimal EasyScheduledTask stub (for Scheduler integration)
  class FakeScheduledTask
    include Easyop::Scheduler::ScheduledTaskModel

    attr_accessor :id, :operation_class, :ctx_data, :run_at, :cron, :parent_id,
                  :state, :claimed_by, :claimed_at, :locked_until, :lock_version,
                  :attempts, :max_attempts, :last_error_class, :last_error_message,
                  :tags, :dedup_key

    @@store = []
    @@next_id = 1

    def self.store = @@store
    def self.reset! = (@@store = []; @@next_id = 1)

    # Minimal connection stub so Scheduler._adapter_name doesn't raise
    def self.connection
      Struct.new(:adapter_name).new('test_adapter')
    end

    def self.create!(attrs)
      obj = new
      attrs.each do |k, v|
        obj.public_send(:"#{k}=", v) if obj.respond_to?(:"#{k}=")
      end
      obj.id       ||= @@next_id
      obj.state    ||= 'scheduled'
      obj.attempts ||= 0
      @@next_id += 1
      @@store << obj
      obj
    end

    def self.find(id)
      @@store.find { |r| r.id == id }
    end

    def self.where(*args, **conditions)
      return ScheduledTaskScope.new(@@store) if args.any? && conditions.empty?

      ScheduledTaskScope.new(@@store.select do |r|
        conditions.all? { |k, v| r.respond_to?(k) && r.public_send(k) == v }
      end)
    end

    def self.claim_due_batch(batch_size:, lock_window:, worker_id:)
      due = @@store.select { |t| t.state == 'scheduled' && t.run_at <= Time.current }
                   .first(batch_size)
      due.each do |t|
        t.state        = 'running'
        t.claimed_by   = worker_id
        t.claimed_at   = Time.current
        t.locked_until = Time.current + lock_window
      end
      due
    end

    def update_columns(attrs)
      attrs.each { |k, v| public_send(:"#{k}=", v) if respond_to?(:"#{k}=") }
      self
    end

    def increment!(attr)
      send(:"#{attr}=", send(attr) + 1)
    end

    class ScheduledTaskScope
      include Enumerable

      def initialize(records) = @records = records
      def each(&blk)          = @records.each(&blk)
      def count               = @records.size

      def where(*args, **conditions)
        return self if args.any? && conditions.empty?   # skip LIKE / jsonb patterns

        ScheduledTaskScope.new(@records.select do |r|
          conditions.all? { |k, v| r.respond_to?(k) && r.public_send(k) == v }
        end)
      end

      def update_all(attrs)
        @records.each { |r| attrs.each { |k, v| r.public_send(:"#{k}=", v) if r.respond_to?(:"#{k}=") } }
        @records.size
      end
    end
  end
end

# Base class for tests that exercise durable-flow machinery.
class PersistentFlowTestBase < Minitest::Test
  include EasyopTestHelper

  def setup
    super
    PersistentFlowTestStubs::FakeFlowRun.reset!
    PersistentFlowTestStubs::FakeFlowRunStep.reset!
    PersistentFlowTestStubs::FakeScheduledTask.reset!

    Easyop.configure do |c|
      c.persistent_flow_model      = 'PersistentFlowTestStubs::FakeFlowRun'
      c.persistent_flow_step_model = 'PersistentFlowTestStubs::FakeFlowRunStep'
      c.scheduler_model            = 'PersistentFlowTestStubs::FakeScheduledTask'
    end
  end

  def flow_runs   = PersistentFlowTestStubs::FakeFlowRun.store
  def flow_steps  = PersistentFlowTestStubs::FakeFlowRunStep.store
  def sched_tasks = PersistentFlowTestStubs::FakeScheduledTask.store

  def make_op(&blk)
    Class.new do
      include Easyop::Operation
      define_method(:call, &blk) if blk
    end
  end

  def make_async_op(&blk)
    Class.new do
      include Easyop::Operation
      plugin Easyop::Plugins::Async
      define_method(:call, &blk) if blk
    end
  end
end
