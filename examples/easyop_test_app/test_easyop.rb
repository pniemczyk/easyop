# frozen_string_literal: true
# Comprehensive test script for the easyop gem.
# Run: cd /tmp/easyop_test_app && ruby -I . test_easyop.rb

$LOAD_PATH.unshift("/app/lib")
require "easyop"

$failures = 0
$passes   = 0

def assert(condition, name)
  if condition
    puts "PASS: #{name}"
    $passes += 1
  else
    puts "FAIL: #{name}"
    $failures += 1
  end
rescue => e
  puts "ERROR: #{name} - #{e.class}: #{e.message}"
  $failures += 1
end

def assert_raises(klass, name)
  yield
  puts "FAIL: #{name} — expected #{klass} to be raised"
  $failures += 1
rescue klass
  puts "PASS: #{name}"
  $passes += 1
rescue => e
  puts "ERROR: #{name} — expected #{klass} but got #{e.class}: #{e.message}"
  $failures += 1
end

def refute(condition, name)
  assert(!condition, name)
end

puts "\n=== Easyop Test Suite ===\n\n"

# ===========================================================================
# 1. Easyop::Ctx — basic construction and attribute access
# ===========================================================================
puts "--- Easyop::Ctx ---"

ctx = Easyop::Ctx.new(name: "Alice", age: 30)
assert ctx[:name] == "Alice", "Ctx hash read [:name]"
assert ctx[:age]  == 30,      "Ctx hash read [:age]"
assert ctx.name   == "Alice", "Ctx method read .name"
assert ctx.age    == 30,      "Ctx method read .age"

ctx[:score] = 99
assert ctx[:score] == 99, "Ctx hash write [:score]"

ctx.score = 100
assert ctx.score == 100, "Ctx method write .score="

assert ctx.key?(:name),  "Ctx#key? returns true for present key"
refute ctx.key?(:missing), "Ctx#key? returns false for missing key"

sliced = ctx.slice(:name, :age)
assert sliced == { name: "Alice", age: 30 }, "Ctx#slice returns matching keys"
assert sliced.is_a?(Hash), "Ctx#slice returns a Hash"

h = ctx.to_h
assert h.is_a?(Hash), "Ctx#to_h returns Hash"
assert h[:name] == "Alice", "Ctx#to_h includes attributes"

# ===========================================================================
# 2. Easyop::Ctx — predicates and fail!
# ===========================================================================
puts "\n--- Easyop::Ctx predicates & fail! ---"

ctx2 = Easyop::Ctx.new
assert  ctx2.success?, "Ctx#success? true by default"
assert  ctx2.ok?,      "Ctx#ok? true by default"
refute  ctx2.failure?, "Ctx#failure? false by default"
refute  ctx2.failed?,  "Ctx#failed? false by default"

begin
  ctx2.fail!(error: "Boom!")
rescue Easyop::Ctx::Failure => e
  assert ctx2.failure?,              "Ctx#failure? true after fail!"
  assert ctx2.failed?,               "Ctx#failed? alias works"
  refute ctx2.success?,              "Ctx#success? false after fail!"
  assert ctx2.error == "Boom!",      "Ctx#error set via fail!"
  assert e.ctx == ctx2,              "Ctx::Failure#ctx points to ctx"
  assert e.message.include?("Boom!"), "Ctx::Failure#message includes error"
end

# fail! with no args
ctx3 = Easyop::Ctx.new
begin
  ctx3.fail!
rescue Easyop::Ctx::Failure
end
assert ctx3.failure?, "Ctx#fail! with no args marks failed"
assert ctx3.errors == {}, "Ctx#errors returns {} when not set"

# ===========================================================================
# 3. Easyop::Ctx — predicate methods via method_missing
# ===========================================================================
puts "\n--- Easyop::Ctx method_missing predicates ---"

ctx4 = Easyop::Ctx.new(active: true, deleted: false, name: "Bob")
assert ctx4.active?,  "Ctx predicate ?-method returns true"
refute ctx4.deleted?, "Ctx predicate ?-method returns false"
assert ctx4.name?,    "Ctx predicate ?-method: truthy string coerced to true"

ctx5 = Easyop::Ctx.new
refute ctx5.missing?, "Ctx predicate ?-method returns false for absent key"

# ===========================================================================
# 4. Easyop::Ctx — on_success / on_failure callbacks
# ===========================================================================
puts "\n--- Easyop::Ctx on_success/on_failure ---"

log = []
ctx6 = Easyop::Ctx.new(value: 42)
ctx6.on_success { |c| log << :success }
   .on_failure  { |c| log << :failure }
assert log == [:success], "on_success fires when success"

log2 = []
ctx7 = Easyop::Ctx.new
begin ctx7.fail! rescue Easyop::Ctx::Failure; end
ctx7.on_success { |c| log2 << :success }
   .on_failure  { |c| log2 << :failure }
assert log2 == [:failure], "on_failure fires when failed"

# ===========================================================================
# 5. Easyop::Ctx — merge!
# ===========================================================================
puts "\n--- Easyop::Ctx merge! ---"

ctx8 = Easyop::Ctx.new(a: 1)
ctx8.merge!(b: 2, c: 3)
assert ctx8[:a] == 1 && ctx8[:b] == 2 && ctx8[:c] == 3, "Ctx#merge! bulk-sets attributes"

# ===========================================================================
# 6. Easyop::Ctx — pattern matching (deconstruct_keys)
# ===========================================================================
puts "\n--- Easyop::Ctx pattern matching ---"

ctx9 = Easyop::Ctx.new(user: "carol", token: "abc123")
matched = case ctx9
          in { success: true, user: String => u }
            u
          else
            :no_match
          end
assert matched == "carol", "Ctx pattern match on success + attribute"

ctx10 = Easyop::Ctx.new(error: "Oops")
begin ctx10.fail! rescue Easyop::Ctx::Failure; end
matched2 = case ctx10
           in { failure: true, error: String => msg }
             msg
           else
             :no_match
           end
assert matched2 == "Oops", "Ctx pattern match on failure + error"

# ===========================================================================
# 7. Easyop::Operation — basic call
# ===========================================================================
puts "\n--- Easyop::Operation basic call ---"

class DoubleOp
  include Easyop::Operation
  def call
    ctx.result = ctx.input * 2
  end
end

result = DoubleOp.call(input: 5)
assert result.is_a?(Easyop::Ctx), "Operation.call returns Ctx"
assert result.success?,           "Operation.call succeeds"
assert result.result == 10,       "Operation sets ctx attributes"

# ===========================================================================
# 8. Easyop::Operation — .call vs .call! on failure
# ===========================================================================
puts "\n--- Easyop::Operation .call vs .call! ---"

class FailingOp
  include Easyop::Operation
  def call
    ctx.fail!(error: "bad input")
  end
end

ctx_safe = FailingOp.call(x: 1)
assert ctx_safe.failure?,               "Operation.call returns failed ctx"
assert ctx_safe.error == "bad input",   "Operation.call sets error"

assert_raises(Easyop::Ctx::Failure, "Operation.call! raises Ctx::Failure") do
  FailingOp.call!(x: 1)
end

begin
  FailingOp.call!(x: 1)
rescue Easyop::Ctx::Failure => e
  assert e.ctx.failure?, "Ctx::Failure#ctx is failed"
end

# ===========================================================================
# 9. Easyop::Operation — no-op (empty call)
# ===========================================================================
puts "\n--- Easyop::Operation no-op ---"

class NoOpOp
  include Easyop::Operation
end

r = NoOpOp.call
assert r.success?, "No-op operation succeeds"

# ===========================================================================
# 10. Easyop::Hooks — before hooks (symbol and block)
# ===========================================================================
puts "\n--- Easyop::Hooks before ---"

log = []

class BeforeHookOp
  include Easyop::Operation

  before :normalize_email
  before { |*| }  # block form — needs self access via instance_exec

  def call
    # email already normalized
  end

  private

  def normalize_email
    ctx.email = ctx.email.downcase if ctx.email
  end
end

# Re-test with actual tracking
class BeforeTrackOp
  include Easyop::Operation
  @@trace = []
  before :step_one
  before { @@trace << :block_before }

  def call
    @@trace << :call
  end

  def self.trace; @@trace; end

  private
  def step_one
    @@trace << :step_one
  end
end

BeforeTrackOp.call
assert BeforeTrackOp.trace == [:step_one, :block_before, :call],
       "before hooks run in order before call"

r = BeforeHookOp.call(email: "ALICE@Example.COM")
assert r.success?, "before hook (symbol) runs without error"

# ===========================================================================
# 11. Easyop::Hooks — after hooks
# ===========================================================================
puts "\n--- Easyop::Hooks after ---"

class AfterTrackOp
  include Easyop::Operation
  @@trace = []
  after :step_after
  after { @@trace << :block_after }

  def call
    @@trace << :call
  end

  def self.trace; @@trace; end

  private
  def step_after
    @@trace << :step_after
  end
end

AfterTrackOp.call
assert AfterTrackOp.trace == [:call, :step_after, :block_after],
       "after hooks run in order after call"

# after runs even when call fails (ensure)
class AfterOnFailOp
  include Easyop::Operation
  @@after_ran = false
  after { @@after_ran = true }

  def call
    ctx.fail!(error: "nope")
  end

  def self.after_ran?; @@after_ran; end
end

AfterOnFailOp.call
assert AfterOnFailOp.after_ran?, "after hook still runs when fail! is called"

# ===========================================================================
# 12. Easyop::Hooks — around hooks
# ===========================================================================
puts "\n--- Easyop::Hooks around ---"

class AroundTrackOp
  include Easyop::Operation
  @@trace = []
  around :wrap_it
  around { |inner| @@trace << :around_block_before; inner.call; @@trace << :around_block_after }

  def call
    @@trace << :call
  end

  def self.trace; @@trace; end

  private
  def wrap_it
    @@trace << :around_before
    yield
    @@trace << :around_after
  end
end

AroundTrackOp.call
assert AroundTrackOp.trace == [:around_before, :around_block_before, :call, :around_block_after, :around_after],
       "around hooks wrap correctly (outermost first)"

# ===========================================================================
# 13. Easyop::Rescuable — rescue_from with block
# ===========================================================================
puts "\n--- Easyop::Rescuable rescue_from ---"

class RescueBlockOp
  include Easyop::Operation

  rescue_from ArgumentError do |e|
    ctx.fail!(error: "Rescued: #{e.message}")
  end

  def call
    raise ArgumentError, "bad arg"
  end
end

r = RescueBlockOp.call
assert r.failure?,                         "rescue_from block marks ctx failed"
assert r.error == "Rescued: bad arg",      "rescue_from block sets error message"

# rescue_from with with: :method_name
class RescueSymbolOp
  include Easyop::Operation

  rescue_from RuntimeError, with: :handle_runtime

  def call
    raise RuntimeError, "runtime!"
  end

  private

  def handle_runtime(e)
    ctx.fail!(error: "Handled: #{e.message}")
  end
end

r = RescueSymbolOp.call
assert r.failure?,                          "rescue_from with: symbol marks ctx failed"
assert r.error == "Handled: runtime!",      "rescue_from with: symbol sets error"

# unhandled exception re-raises
class UnhandledExOp
  include Easyop::Operation
  def call
    raise TypeError, "type error"
  end
end

begin
  UnhandledExOp.call
  assert false, "Unhandled exception should re-raise via call"
rescue TypeError
  assert true, "Unhandled exception propagates from .call"
end

# ===========================================================================
# 14. Easyop::Schema — params DSL required/optional with defaults
# ===========================================================================
puts "\n--- Easyop::Schema params ---"

class SchemaParamsOp
  include Easyop::Operation

  params do
    required :email,    String
    optional :notify,   :boolean, default: true
    optional :note,     String
  end

  def call
    ctx.result = "#{ctx.email}:#{ctx.notify}"
  end
end

# Valid call
r = SchemaParamsOp.call(email: "test@example.com")
assert r.success?,                                "Schema params: valid required field passes"
assert r.notify == true,                          "Schema params: default applied for optional"
assert r.result == "test@example.com:true",       "Schema params: values available in call"

# Missing required field
r2 = SchemaParamsOp.call(notify: false)
assert r2.failure?,                               "Schema params: missing required field fails"
assert r2.error.include?("Missing required"),     "Schema params: missing field error message"
assert r2.errors[:email] == "is required",        "Schema params: errors hash set"

# Type mismatch (strict_types off by default — warns only)
Easyop.configure { |c| c.strict_types = true }
r3 = SchemaParamsOp.call(email: 123)
assert r3.failure?,                               "Schema params: type mismatch fails (strict_types=true)"
assert r3.error.include?("Type mismatch"),        "Schema params: type mismatch error message"
Easyop.reset_config!

# ===========================================================================
# 15. Easyop::Schema — result DSL
# ===========================================================================
puts "\n--- Easyop::Schema result ---"

Easyop.configure { |c| c.strict_types = true }

class SchemaResultOp
  include Easyop::Operation

  result do
    required :output, String
  end

  def call
    ctx.output = "done"
  end
end

r = SchemaResultOp.call
assert r.success?,             "Schema result: valid output passes"
assert r.output == "done",     "Schema result: output attribute set"

class SchemaResultBadOp
  include Easyop::Operation

  result do
    required :output, String
  end

  def call
    ctx.output = 42  # wrong type
  end
end

r2 = SchemaResultBadOp.call
assert r2.failure?,                    "Schema result: wrong type fails (strict_types=true)"
assert r2.error.include?("Type mismatch"), "Schema result: type error message"

Easyop.reset_config!

# ===========================================================================
# 16. Easyop::Schema — type shorthands
# ===========================================================================
puts "\n--- Easyop::Schema type shorthands ---"

class SchemaTypesOp
  include Easyop::Operation

  params do
    required :flag,    :boolean
    required :count,   :integer
    required :ratio,   :float
    required :label,   :string
    required :sym,     :symbol
    optional :generic, :any
  end

  def call
    ctx.ok = true
  end
end

Easyop.configure { |c| c.strict_types = true }
r = SchemaTypesOp.call(flag: true, count: 5, ratio: 1.5, label: "hi", sym: :foo)
assert r.success?, "Schema type shorthands: all valid types pass"

r2 = SchemaTypesOp.call(flag: "yes", count: 5, ratio: 1.5, label: "hi", sym: :foo)
assert r2.failure?, "Schema type shorthand :boolean rejects String"
Easyop.reset_config!

# ===========================================================================
# 17. Easyop::Skip — skip_if on flow steps
# ===========================================================================
puts "\n--- Easyop::Skip skip_if ---"

class SkippableStep
  include Easyop::Operation

  skip_if { |ctx| ctx.skip_step == true }

  def call
    ctx.step_ran = true
  end
end

class SkipFlow
  include Easyop::Flow
  flow SkippableStep
end

r = SkipFlow.call(skip_step: true)
assert r.success?,          "skip_if: flow succeeds when step skipped"
assert r[:step_ran].nil?,   "skip_if: skipped step does not run"

r2 = SkipFlow.call(skip_step: false)
assert r2.success?,         "skip_if: flow succeeds when step runs"
assert r2.step_ran == true, "skip_if: step runs when condition is false"

# ===========================================================================
# 18. Easyop::Flow — sequential operations
# ===========================================================================
puts "\n--- Easyop::Flow sequential ---"

class StepA
  include Easyop::Operation
  def call
    ctx[:log] = (ctx[:log] || []) << :a
    ctx.value = 1
  end
end

class StepB
  include Easyop::Operation
  def call
    ctx[:log] = (ctx[:log] || []) << :b
    ctx.value = ctx.value + 1
  end
end

class StepC
  include Easyop::Operation
  def call
    ctx[:log] = (ctx[:log] || []) << :c
    ctx.value = ctx.value * 3
  end
end

class MultiStepFlow
  include Easyop::Flow
  flow StepA, StepB, StepC
end

r = MultiStepFlow.call
assert r.success?,          "Flow: sequential steps all run"
assert r[:log] == [:a, :b, :c], "Flow: steps run in order"
assert r.value == 6,        "Flow: ctx shared and mutated across steps (1+1=2, 2*3=6)"

# ===========================================================================
# 19. Easyop::Flow — failure halts execution
# ===========================================================================
puts "\n--- Easyop::Flow failure halts ---"

class FailStep
  include Easyop::Operation
  def call
    ctx.fail!(error: "step failed")
  end
end

class StepAfterFail
  include Easyop::Operation
  def call
    ctx.after_fail_ran = true
  end
end

class HaltFlow
  include Easyop::Flow
  flow StepA, FailStep, StepAfterFail
end

r = HaltFlow.call
assert r.failure?,                  "Flow: failure halts execution"
assert r.error == "step failed",    "Flow: failure error propagated"
assert r[:after_fail_ran].nil?,     "Flow: steps after failure do not run"

# ===========================================================================
# 20. Easyop::Flow — rollback on failure
# ===========================================================================
puts "\n--- Easyop::Flow rollback ---"

$rollback_log = []

class RollbackStepA
  include Easyop::Operation
  def call
    ctx[:log] = (ctx[:log] || []) << :a_call
  end
  def rollback
    $rollback_log << :a_rollback
  end
end

class RollbackStepB
  include Easyop::Operation
  def call
    ctx[:log] = (ctx[:log] || []) << :b_call
  end
  def rollback
    $rollback_log << :b_rollback
  end
end

class RollbackStepFail
  include Easyop::Operation
  def call
    ctx.fail!(error: "rollback test")
  end
end

class RollbackFlow
  include Easyop::Flow
  flow RollbackStepA, RollbackStepB, RollbackStepFail
end

r = RollbackFlow.call
assert r.failure?,                                  "Rollback flow: fails"
assert $rollback_log == [:b_rollback, :a_rollback], "Rollback: called in reverse order"

# ===========================================================================
# 21. Easyop::Flow — lambda guard (conditional step)
# ===========================================================================
puts "\n--- Easyop::Flow lambda guard ---"

class ConditionalStep
  include Easyop::Operation
  def call
    ctx.conditional_ran = true
  end
end

class GuardedFlow
  include Easyop::Flow
  flow StepA,
       ->(ctx) { ctx.run_conditional == true }, ConditionalStep,
       StepB
end

r = GuardedFlow.call(run_conditional: false)
assert r.success?,                      "Lambda guard: flow succeeds when step skipped"
assert r[:conditional_ran].nil?,        "Lambda guard: step skipped when guard returns false"
assert r[:log]&.include?(:b),           "Lambda guard: subsequent steps still run"

r2 = GuardedFlow.call(run_conditional: true)
assert r2.success?,                     "Lambda guard: flow succeeds when step runs"
assert r2.conditional_ran == true,      "Lambda guard: step runs when guard returns true"

# ===========================================================================
# 22. Easyop::FlowBuilder — prepare, on_success, on_failure
# ===========================================================================
puts "\n--- Easyop::FlowBuilder ---"

class SimpleFlow
  include Easyop::Flow
  flow StepA, StepB
end

success_log = []
fail_log    = []

r = SimpleFlow.prepare
              .on_success { |ctx| success_log << ctx.value }
              .on_failure { |ctx| fail_log    << ctx.error }
              .call

assert r.success?,            "FlowBuilder on_success: flow succeeds"
assert success_log == [2],    "FlowBuilder on_success: callback fires with correct ctx"
assert fail_log    == [],     "FlowBuilder on_failure: not called on success"

class AlwaysFailFlow
  include Easyop::Flow
  flow FailStep
end

success_log2 = []
fail_log2    = []

r2 = AlwaysFailFlow.prepare
                   .on_success { |ctx| success_log2 << :win }
                   .on_failure { |ctx| fail_log2    << ctx.error }
                   .call

assert r2.failure?,                      "FlowBuilder on_failure: flow fails"
assert fail_log2    == ["step failed"],  "FlowBuilder on_failure: callback fires"
assert success_log2 == [],               "FlowBuilder on_success: not called on failure"

# ===========================================================================
# 23. Easyop::FlowBuilder — bind_with and .on
# ===========================================================================
puts "\n--- Easyop::FlowBuilder bind_with + .on ---"

class BoundTarget
  attr_reader :success_called, :fail_called

  def initialize
    @success_called = false
    @fail_called    = false
  end

  def handle_success(ctx)
    @success_called = ctx.value
  end

  def handle_failure(ctx)
    @fail_called = ctx.error
  end
end

target = BoundTarget.new
SimpleFlow.prepare
          .bind_with(target)
          .on(success: :handle_success, fail: :handle_failure)
          .call

assert target.success_called == 2,   "FlowBuilder bind_with: success method called with ctx"
assert target.fail_called    == false, "FlowBuilder bind_with: fail not called on success"

target2 = BoundTarget.new
AlwaysFailFlow.prepare
              .bind_with(target2)
              .on(success: :handle_success, fail: :handle_failure)
              .call

assert target2.success_called == false,       "FlowBuilder bind_with: success not called on failure"
assert target2.fail_called    == "step failed", "FlowBuilder bind_with: fail method called"

# ===========================================================================
# 24. Easyop::FlowBuilder — bind_with 0-arity methods
# ===========================================================================
puts "\n--- Easyop::FlowBuilder bind_with 0-arity ---"

class NoArgTarget
  attr_reader :success_called, :fail_called

  def initialize
    @success_called = false
    @fail_called    = false
  end

  def handle_success
    @success_called = true
  end

  def handle_failure
    @fail_called = true
  end
end

target3 = NoArgTarget.new
SimpleFlow.prepare
          .bind_with(target3)
          .on(success: :handle_success, fail: :handle_failure)
          .call

assert target3.success_called == true,  "FlowBuilder 0-arity: success method called"
assert target3.fail_called    == false, "FlowBuilder 0-arity: fail not called"

# ===========================================================================
# 25. Inheritance — shared base operations
# ===========================================================================
puts "\n--- Inheritance ---"

class BaseOp
  include Easyop::Operation

  rescue_from StandardError, with: :handle_base_error

  before :set_base_attr

  private

  def set_base_attr
    ctx.base_set = true
  end

  def handle_base_error(e)
    ctx.fail!(error: "Base handled: #{e.message}")
  end
end

class ChildOp < BaseOp
  def call
    ctx.child_ran = true
  end
end

r = ChildOp.call
assert r.success?,            "Inheritance: child op runs"
assert r.base_set == true,    "Inheritance: parent before hook runs in child"
assert r.child_ran == true,   "Inheritance: child call runs"

# Inherited rescue_from
class ChildWithErrorOp < BaseOp
  def call
    raise RuntimeError, "child error"
  end
end

r2 = ChildWithErrorOp.call
assert r2.failure?,                              "Inheritance: parent rescue_from fires in child"
assert r2.error == "Base handled: child error",  "Inheritance: parent rescue_from message"

# Child adding its own hooks without affecting parent
class ChildWithExtraHookOp < BaseOp
  after { ctx.child_after_ran = true }

  def call
    ctx.child_ran = true
  end
end

r3 = ChildWithExtraHookOp.call
assert r3.child_after_ran == true, "Inheritance: child-specific after hook runs"

r4 = ChildOp.call
assert r4[:child_after_ran].nil?, "Inheritance: child hook does not affect parent/sibling"

# ===========================================================================
# 26. Easyop::Ctx — Ctx.build
# ===========================================================================
puts "\n--- Easyop::Ctx.build ---"

existing = Easyop::Ctx.new(x: 1)
built = Easyop::Ctx.build(existing)
assert built.equal?(existing), "Ctx.build returns same instance if already a Ctx"

built2 = Easyop::Ctx.build(y: 2)
assert built2.is_a?(Easyop::Ctx), "Ctx.build creates new Ctx from Hash"
assert built2[:y] == 2,           "Ctx.build sets attributes from Hash"

# ===========================================================================
# 27. Easyop::Configuration
# ===========================================================================
puts "\n--- Easyop::Configuration ---"

assert Easyop.config.is_a?(Easyop::Configuration), "Easyop.config returns Configuration"
assert Easyop.config.type_adapter == :native,       "Config default type_adapter is :native"
assert Easyop.config.strict_types == false,         "Config default strict_types is false"

Easyop.configure do |c|
  c.type_adapter = :none
  c.strict_types = true
end
assert Easyop.config.type_adapter == :none,  "Config type_adapter can be set"
assert Easyop.config.strict_types == true,   "Config strict_types can be set"

Easyop.reset_config!
assert Easyop.config.type_adapter == :native, "Config reset restores defaults"
assert Easyop.config.strict_types == false,   "Config reset restores strict_types"

# ===========================================================================
# 28. Easyop::Operation — unhandled exception marks ctx failed via .call
# ===========================================================================
puts "\n--- Operation unhandled exception in .call ---"

class BoomOp
  include Easyop::Operation
  def call
    raise RuntimeError, "unexpected boom"
  end
end

begin
  BoomOp.call
  assert false, "Unhandled exception should re-raise from .call"
rescue RuntimeError => e
  assert e.message == "unexpected boom", "Unhandled exception propagates from .call"
end

# ===========================================================================
# 29. Easyop::Operation — .call! propagates Ctx::Failure
# ===========================================================================
puts "\n--- Operation .call! propagates Ctx::Failure ---"

class FailableOp
  include Easyop::Operation
  def call
    ctx.fail!(error: "call! test")
  end
end

begin
  FailableOp.call!
  assert false, ".call! should raise Ctx::Failure"
rescue Easyop::Ctx::Failure => e
  assert e.ctx.failure?,               ".call! raises Ctx::Failure with failed ctx"
  assert e.ctx.error == "call! test",  ".call! Ctx::Failure carries error"
end

# ===========================================================================
# 30. Easyop::Flow — call! raises on failure
# ===========================================================================
puts "\n--- Easyop::Flow .call! ---"

assert_raises(Easyop::Ctx::Failure, "Flow.call! raises Ctx::Failure on failure") do
  AlwaysFailFlow.call!
end

r = SimpleFlow.call!
assert r.success?, "Flow.call! returns ctx on success"

# ===========================================================================
# 31. Easyop::Schema — aliases inputs/outputs
# ===========================================================================
puts "\n--- Easyop::Schema aliases ---"

class AliasSchemaOp
  include Easyop::Operation

  inputs do
    required :name, String
  end

  outputs do
    required :greeting, String
  end

  def call
    ctx.greeting = "Hello, #{ctx.name}!"
  end
end

r = AliasSchemaOp.call(name: "World")
assert r.success?,                    "Schema alias inputs/outputs: op succeeds"
assert r.greeting == "Hello, World!", "Schema alias: outputs applied"

# ===========================================================================
# 32. Easyop::Schema — optional field with default (callable)
# ===========================================================================
puts "\n--- Easyop::Schema optional callable default ---"

class CallableDefaultOp
  include Easyop::Operation

  params do
    optional :generated, String, default: -> { "auto-#{rand(1000)}" }
  end

  def call
    ctx.result = ctx.generated
  end
end

r = CallableDefaultOp.call
assert r.success?,                 "Schema callable default: op succeeds"
assert r.generated.is_a?(String),  "Schema callable default: String value generated"
assert r.generated.start_with?("auto-"), "Schema callable default: lambda called"

# ===========================================================================
# 33. Rescuable — multiple exception classes in one rescue_from
# ===========================================================================
puts "\n--- Rescuable multiple exception classes ---"

class MultiRescueOp
  include Easyop::Operation

  rescue_from ArgumentError, TypeError do |e|
    ctx.fail!(error: "multi: #{e.message}")
  end

  def call
    raise ctx.exception_class.constantize, "test" if ctx.exception_class
  rescue NameError
    # constantize not available — use case/when
    case ctx.exception_name
    when "ArgumentError" then raise ArgumentError, "test"
    when "TypeError"     then raise TypeError, "test"
    end
  end
end

# Simpler approach without constantize
class MultiRescueArgOp
  include Easyop::Operation

  rescue_from ArgumentError, TypeError do |e|
    ctx.fail!(error: "multi: #{e.message}")
  end

  def call
    raise ArgumentError, "arg error"
  end
end

class MultiRescueTypeOp
  include Easyop::Operation

  rescue_from ArgumentError, TypeError do |e|
    ctx.fail!(error: "multi: #{e.message}")
  end

  def call
    raise TypeError, "type error"
  end
end

r1 = MultiRescueArgOp.call
assert r1.failure? && r1.error == "multi: arg error",   "Rescuable: first of multiple classes caught"

r2 = MultiRescueTypeOp.call
assert r2.failure? && r2.error == "multi: type error",  "Rescuable: second of multiple classes caught"

# ===========================================================================
# 34. Easyop::Flow — ctx.call! semantics within flow
# ===========================================================================
puts "\n--- Easyop::Flow ctx shared across all steps ---"

class SharedCtxStep1
  include Easyop::Operation
  def call
    ctx.shared = "from_step1"
    ctx.counter = 0
  end
end

class SharedCtxStep2
  include Easyop::Operation
  def call
    ctx.counter += 1
    ctx.also_from_2 = "yes"
  end
end

class SharedCtxStep3
  include Easyop::Operation
  def call
    ctx.counter += 1
    ctx.final = ctx.shared + ":done"
  end
end

class SharedCtxFlow
  include Easyop::Flow
  flow SharedCtxStep1, SharedCtxStep2, SharedCtxStep3
end

r = SharedCtxFlow.call
assert r.success?,                   "Shared ctx flow: succeeds"
assert r.counter == 2,               "Shared ctx: counter incremented by 2 steps"
assert r.final == "from_step1:done", "Shared ctx: value from step1 visible in step3"
assert r.also_from_2 == "yes",       "Shared ctx: step2 value visible in result"

# ===========================================================================
# 35. Easyop::Ctx — errors defaults to empty hash
# ===========================================================================
puts "\n--- Easyop::Ctx errors default ---"

ctx_e = Easyop::Ctx.new
assert ctx_e.errors == {}, "Ctx#errors returns {} by default"

ctx_e.errors = { name: "is required" }
assert ctx_e.errors == { name: "is required" }, "Ctx#errors= sets errors hash"

# ===========================================================================
# 36. Hooks inheritance — child does not pollute parent
# ===========================================================================
puts "\n--- Hooks inheritance isolation ---"

# Use ctx to track hooks so both parent and child write to the same place
class ParentHookOp2
  include Easyop::Operation
  before { ctx[:htrace] = (ctx[:htrace] || []) << :parent_before }
  def call
    ctx[:htrace] = (ctx[:htrace] || []) << :call
  end
end

class ChildHookOp2 < ParentHookOp2
  before { ctx[:htrace] = (ctx[:htrace] || []) << :child_before }
  def call
    ctx[:htrace] = (ctx[:htrace] || []) << :call
  end
end

r_parent = ParentHookOp2.call
assert r_parent[:htrace] == [:parent_before, :call],
       "Parent hooks: only parent before runs"

r_child = ChildHookOp2.call
assert r_child[:htrace] == [:parent_before, :child_before, :call],
       "Child hooks: inherits parent before, adds own"

# Ensure parent wasn't contaminated
assert ParentHookOp2._before_hooks.length == 1, "Parent hooks not contaminated by child"

# ===========================================================================
# 37. Easyop::Ctx — inspect
# ===========================================================================
puts "\n--- Easyop::Ctx inspect ---"

ctx_i = Easyop::Ctx.new(x: 1)
assert ctx_i.inspect.include?("ok"),       "Ctx#inspect shows 'ok' when success"
begin ctx_i.fail! rescue Easyop::Ctx::Failure; end
assert ctx_i.inspect.include?("FAILED"),   "Ctx#inspect shows 'FAILED' when failed"

# ===========================================================================
# 38. Async Flows — Mode 2 (fire-and-forget) and Mode 3 (durable with waits)
# ===========================================================================
#
# These sections test the v0.5 unified Easyop::Flow API.
#
# Mode 2: flow with .async step but NO `subject` — returns Ctx, step fires async
# Mode 3: flow with `subject :user` — returns EasyFlowRun, steps persist + resume
#
# Because test_easyop.rb is a standalone script (no Rails boot), Mode 3 uses
# in-memory FakeFlowRun/FakeScheduledTask stubs identical to 08_durable_workflow.rb.
# In the actual Rails app the real EasyFlowRun / EasyScheduledTask AR models are
# used (see app/models/ and the migrations).

puts "\n--- Async / Mode 2 / Mode 3 ---"

require "easyop/plugins/async"
require "easyop/persistent_flow"
require "easyop/scheduler"

# Time.current shim for standalone use
unless Time.respond_to?(:current)
  class Time
    def self.current; now; end
  end
end

# String#constantize shim
unless ''.respond_to?(:constantize)
  class String
    def constantize; Object.const_get(self); end
  end
end

# ── Minimal AR stubs (in-memory, no database) ────────────────────────────────

class AsyncTestScope
  include Enumerable
  def initialize(records) = @records = records
  def each(&b)            = @records.each(&b)
  def count               = @records.size
  def first               = @records.first
  def exists?             = @records.any?
  def where(**c)          = AsyncTestScope.new(@records.select { |r| c.all? { |k,v| r.public_send(k) == v } })
  def update_all(**attrs) = @records.each { |r| attrs.each { |k,v| r.public_send(:"#{k}=", v) } } && @records.size
end

class AsyncTestFlowRun
  include Easyop::PersistentFlow::FlowRunModel

  attr_accessor :id, :flow_class, :context_data, :status, :current_step_index,
                :subject_type, :subject_id, :started_at, :finished_at

  @@store = []; @@seq = 0
  def self.store;   @@store; end
  def self.reset!;  @@store = []; @@seq = 0; end
  def self.create!(attrs)
    obj = new; attrs.each { |k,v| obj.public_send(:"#{k}=", v) }
    @@seq += 1; obj.id = @@seq; @@store << obj; obj
  end
  def self.find(id) = @@store.find { |r| r.id == id.to_i } || raise("AsyncTestFlowRun #{id} not found")
  def self.where(*a, **c)
    return AsyncTestScope.new(@@store) if a.any? && c.empty?
    AsyncTestScope.new(@@store.select { |r| c.all? { |k,v| r.public_send(k) == v } })
  end
  def initialize; @status = 'pending'; @current_step_index = 0; @context_data = '{}'; end
  def update!(a)        = a.each { |k,v| public_send(:"#{k}=", v) } && self
  def update_columns(a) = update!(a)
  def reload            = self
end

class AsyncTestFlowRunStep
  include Easyop::PersistentFlow::FlowRunStepModel

  attr_accessor :id, :flow_run_id, :step_index, :operation_class, :status,
                :attempt, :error_class, :error_message, :started_at, :finished_at

  @@store = []; @@seq = 0
  def self.store;   @@store; end
  def self.reset!;  @@store = []; @@seq = 0; end
  def self.create!(attrs)
    obj = new; attrs.each { |k,v| obj.public_send(:"#{k}=", v) }
    @@seq += 1; obj.id = @@seq; @@store << obj; obj
  end
  def self.find(id) = @@store.find { |r| r.id == id.to_i }
  def self.where(*a, **c)
    return AsyncTestScope.new(@@store) if a.any? && c.empty?
    AsyncTestScope.new(@@store.select { |r| c.all? { |k,v| r.public_send(k) == v } })
  end
  def initialize;        @status = 'running'; @attempt = 0; end
  def update_columns(a) = a.each { |k,v| public_send(:"#{k}=", v) } && self
end

class AsyncTestScheduledTask
  attr_accessor :id, :operation_class, :ctx_data, :run_at, :tags, :state

  @@store = []; @@seq = 0
  def self.store;   @@store; end
  def self.reset!;  @@store = []; @@seq = 0; end
  def self.connection = Struct.new(:adapter_name).new('fake')
  def self.create!(attrs)
    obj = new; attrs.each { |k,v| obj.public_send(:"#{k}=", v) if obj.respond_to?(:"#{k}=") }
    @@seq += 1; obj.id ||= @@seq; obj.state ||= 'scheduled'; @@store << obj; obj
  end
  def self.find(id)  = @@store.find { |r| r.id == id }
  def self.where(*a, **c)
    return AsyncTestScope.new(@@store) if a.any? && c.empty?
    AsyncTestScope.new(@@store.select { |r| c.all? { |k,v| r.respond_to?(k) && r.public_send(k) == v } })
  end
  def update_columns(a) = a.each { |k,v| public_send(:"#{k}=", v) if respond_to?(:"#{k}=") } && self
  def initialize; @state = 'scheduled'; end
end

# Configure Easyop to use the in-memory stubs for this section
Easyop.configure do |c|
  c.persistent_flow_model      = 'AsyncTestFlowRun'
  c.persistent_flow_step_model = 'AsyncTestFlowRunStep'
  c.scheduler_model            = 'AsyncTestScheduledTask'
end

# Fake user subject (no real AR needed)
unless defined?(ActiveRecord)
  module ActiveRecord; class Base; end; end
end

class AsyncTestUser < ActiveRecord::Base
  @@store = {}
  def self.store        = @@store
  def self.reset!       = (@@store = {})
  def self.find(id)     = @@store.fetch(id.to_i) { raise "AsyncTestUser #{id} not found" }
  def self.create!(attrs)
    id = (@@store.keys.max || 0) + 1
    u  = new(id: id, **attrs); @@store[id] = u; u
  end
  attr_accessor :id, :email
  def initialize(id: nil, email:)
    @id = id; @email = email; @@store[@id] = self if @id
  end
end

# Speedrun helper — drives all pending tasks for a flow_run without real clock
def async_speedrun(flow_run, max: 10)
  max.times do
    break if flow_run.terminal?
    task = AsyncTestScheduledTask.store.find do |t|
      t.state == 'scheduled' &&
        Easyop::Scheduler::Serializer.deserialize(t.ctx_data)[:flow_run_id] == flow_run.id
    end
    break unless task
    task.state = 'running'
    Easyop::PersistentFlow::Runner.execute_scheduled_step!(flow_run)
  end
  flow_run.reload
end

def async_reset!
  AsyncTestFlowRun.reset!
  AsyncTestFlowRunStep.reset!
  AsyncTestScheduledTask.reset!
  AsyncTestUser.reset!
end

# ── Mode 2: fire-and-forget async (no subject) ────────────────────────────────

puts "\nMode 2 — fire-and-forget async (no subject)"

class AsyncOp1Test38
  include Easyop::Operation
  def call; ctx.step1_done = true; end
end

class AsyncOp2Test38
  include Easyop::Operation
  plugin Easyop::Plugins::Async
  def call; ctx.step2_done = true; end
end

class Mode2FlowTest38
  include Easyop::Flow
  flow AsyncOp1Test38, AsyncOp2Test38.async   # no subject → Mode 2
end

# Capture async calls via the built-in spy (no real ActiveJob needed)
captured = []
Thread.current[:_easyop_async_capture]      = captured
Thread.current[:_easyop_async_capture_only] = true   # capture only, don't execute

mode2_result = Mode2FlowTest38.call(value: 'hello')

Thread.current[:_easyop_async_capture]      = nil
Thread.current[:_easyop_async_capture_only] = nil

assert mode2_result.is_a?(Easyop::Ctx),   "Mode 2: .call returns Ctx (not FlowRun)"
assert mode2_result.step1_done == true,    "Mode 2: sync step ran before async step"
assert captured.size == 1,                 "Mode 2: async step captured (enqueued once)"
assert captured.first[:operation] == AsyncOp2Test38, "Mode 2: correct op captured"

# ── Mode 3: durable flow with chained async waits (with subject) ──────────────

puts "\nMode 3 — durable flow with chained .async(wait:) steps"
async_reset!

class Drip1Test38
  include Easyop::Operation
  plugin Easyop::Plugins::Async   # needed for .async step-builder on this class
  def call
    ctx.drip1_sent = true
    puts "  [Drip1Test38] sent immediately for user ##{ctx.user.id}"
  end
end

class Drip2Test38
  include Easyop::Operation
  plugin Easyop::Plugins::Async
  def call
    ctx.drip2_sent = true
    puts "  [Drip2Test38] sent after wait: 5 for user ##{ctx.user.id}"
  end
end

class Drip3Test38
  include Easyop::Operation
  plugin Easyop::Plugins::Async
  def call
    ctx.drip3_sent = true
    puts "  [Drip3Test38] sent after wait: 10 for user ##{ctx.user.id}"
  end
end

class DripFlow38
  include Easyop::Flow
  subject :user   # triggers Mode 3 — .call returns FlowRun
  flow Drip1Test38.async,
       Drip2Test38.async(wait: 5),
       Drip3Test38.async(wait: 10)
end

test_user38 = AsyncTestUser.create!(email: 'test@example.com')
mode3_result = DripFlow38.call(user: test_user38)

assert mode3_result.is_a?(AsyncTestFlowRun), "Mode 3: .call returns FlowRun"
assert mode3_result.status == 'running',     "Mode 3: initial status is 'running'"
assert AsyncTestScheduledTask.store.any? { |t| t.state == 'scheduled' },
       "Mode 3: first async step scheduled immediately"

# Drain all three steps via speedrun
async_speedrun(mode3_result)

assert mode3_result.status == 'succeeded',  "Mode 3: FlowRun succeeded after all steps"

steps38 = AsyncTestFlowRunStep.store.select { |s| s.flow_run_id == mode3_result.id }
assert steps38.size == 3,                   "Mode 3: 3 step records created"
assert steps38.all? { |s| s.status == 'completed' }, "Mode 3: all steps completed"

# Verify steps ran in order and set ctx values
# (context_data is JSON so we deserialize to check)
final_ctx = Easyop::Scheduler::Serializer.deserialize(mode3_result.context_data)
assert final_ctx[:drip1_sent] == true, "Mode 3: drip1 marked in ctx"
assert final_ctx[:drip2_sent] == true, "Mode 3: drip2 marked in ctx"
assert final_ctx[:drip3_sent] == true, "Mode 3: drip3 marked in ctx"

remaining_tasks = AsyncTestScheduledTask.store.count { |t| t.state == 'scheduled' }
assert remaining_tasks == 0, "Mode 3: no pending scheduled tasks after completion"

puts "\nMode 3 subject stored on FlowRun"
assert mode3_result.subject_type == 'AsyncTestUser', "Mode 3: subject_type stored"
assert mode3_result.subject_id   == test_user38.id,  "Mode 3: subject_id stored"

# ===========================================================================
# Summary
# ===========================================================================
puts "\n" + "=" * 50
puts "Results: #{$passes} passed, #{$failures} failed"
puts "=" * 50

exit($failures > 0 ? 1 : 0)
