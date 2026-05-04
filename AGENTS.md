# AGENTS.md — EasyOp

This file is the primary context document for AI agents and LLMs working on
this gem. Read it fully before making any changes.

---

## What this gem does

`easyop` wraps business logic in composable, testable operation objects. Each
operation shares a single `ctx` (context) object that carries inputs, outputs,
and the success/failure signal.

```ruby
class AuthenticateUser
  include Easyop::Operation

  def call
    user = User.authenticate(ctx.email, ctx.password)
    ctx.fail!(error: "Invalid credentials") unless user
    ctx.user = user
  end
end

result = AuthenticateUser.call(email: "alice@example.com", password: "hunter2")
result.success?  # => true
result.user      # => #<User ...>
```

It is a **plain Ruby** gem with no required runtime dependencies. It works in
Rails, Sinatra, Hanami, or standalone Ruby scripts.

---

## File map

```
lib/
  easyop.rb                        # Entry point — requires all modules
  easyop/
    version.rb                     # VERSION = "0.1.7"
    configuration.rb               # Easyop.configure { |c| ... }
    ctx.rb                         # Easyop::Ctx — the shared context/result object
    hooks.rb                       # Easyop::Hooks — before/after/around DSL
    rescuable.rb                   # Easyop::Rescuable — rescue_from DSL
    skip.rb                        # Easyop::Skip — skip_if DSL for flow steps
    schema.rb                      # Easyop::Schema — params/result typed schema DSL
    operation.rb                   # Easyop::Operation — the core mixin
    flow_builder.rb                # Easyop::FlowBuilder — pre-registered callbacks
    flow.rb                        # Easyop::Flow — sequential operation composition
    adapters/                      # (reserved for future type adapter backends)
    plugins/
      transactional.rb             # Easyop::Plugins::Transactional — DB transaction wrap
      events.rb                    # Easyop::Plugins::Events — domain event producer (emits DSL)
      event_handlers.rb            # Easyop::Plugins::EventHandlers — domain event subscriber (on DSL)
    events/
      event.rb                     # Easyop::Events::Event — immutable frozen value object
      bus.rb                       # Easyop::Events::Bus::Base — adapter interface + glob helpers
      bus/
        memory.rb                  # Easyop::Events::Bus::Memory — in-process, thread-safe
        active_support_notifications.rb  # Easyop::Events::Bus::ActiveSupportNotifications
        custom.rb                  # Easyop::Events::Bus::Custom — wraps user-provided adapter
        adapter.rb                 # Easyop::Events::Bus::Adapter — inheritable base for custom buses
      registry.rb                  # Easyop::Events::Registry — global bus + handler registry

test/
  test_helper.rb                   # Minitest setup, AS::Notifications stub, AR stub, EasyopTestHelper
  easyop/
    ctx_test.rb                    # Ctx attribute access, fail!, callbacks, pattern matching
    operation_test.rb              # Operation.call / call!, inheritance, run order
    hooks_test.rb                  # before/after/around hook execution and inheritance
    rescuable_test.rb              # rescue_from, with:, block handlers, inheritance priority
    schema_test.rb                 # params/result DSL, required/optional, type symbols
    flow_test.rb                   # Flow sequential execution, rollback, guards, nesting
    flow_builder_test.rb           # FlowBuilder on_success/on_failure/bind_with/on
    skip_test.rb                   # skip_if DSL — skip predicate, rollback exclusion
    persistent_flow_test.rb        # Mode-3 runner, exception policies, async_retry, blocking:, backoff
    events/
      event_test.rb                # Event construction, immutability, to_h
      registry_test.rb             # Registry bus config, register_handler, dispatch, reset!
      bus/
        memory_test.rb             # Memory bus: publish/subscribe, glob patterns, thread safety
        active_support_notifications_test.rb
        custom_test.rb             # Custom bus: adapter validation, delegation
        adapter_test.rb            # Adapter base: _safe_invoke, _compile_pattern, memoization
    plugins/
      async_test.rb                # Async plugin: call_async, queue DSL, async_retry DSL, serialization
      events_test.rb               # Events plugin: emits DSL, on:, payload:, guard:, inheritance
      event_handlers_test.rb       # EventHandlers plugin: on DSL, wildcard, async dispatch
      recording_test.rb            # Recording plugin: persist, filter, opt-out, flow tracing, record_result DSL, filter_params DSL

examples/
  usage.rb                         # 16 runnable examples (ruby -Ilib examples/usage.rb)
  easyop_test_app/                 # Full Rails 8 blog app demonstrating all plugins
  ticketflow/                      # Full Rails 8 ticket-selling platform (6-step checkout flow,
                                   #   Recording plugin, admin dashboard, skip_if, rollback)

llms/
  overview.md                      # Architecture deep-dive for LLMs
  usage.md                         # Common patterns and recipes

claude-plugin/
  .claude-plugin/
    plugin.json                    # Plugin metadata
  README.md                        # Installation guide
  skills/
    easyop/
      SKILL.md                     # Main skill — auto-loaded when relevant
      references/
        ctx.md                     # Ctx API reference
        operations.md              # Operation DSL reference
        flow.md                    # Flow + FlowBuilder reference
        hooks-and-rescue.md        # Hooks and rescue_from reference
      examples/
        basic_operation.rb         # Single operation patterns
        flow.rb                    # Flow composition patterns
        rails_controller.rb        # Rails controller integration
        testing.rb                 # Minitest and RSpec test patterns

AGENTS.md                          # This file
PROPOSAL.md                        # Design rationale and comparison
README.md                          # Public documentation
```

---

## How to run tests

```bash
# Full suite (preferred)
bundle exec rake test

# Single test file
bundle exec rake test TEST=test/easyop/flow_test.rb

# Single test by name (substring match)
bundle exec rake test TEST=test/easyop/flow_test.rb TESTOPTS="-n /rollback/"

# Run usage examples (integration smoke test)
ruby -Ilib examples/usage.rb
```

Tests use **Minitest** with **SimpleCov** for coverage reporting. There are no
external runtime dependencies — no database, no Rails.

---

## Three-mode dispatch (v0.5)

`Easyop::Flow` auto-selects one of three execution modes. The dispatch lives in
`lib/easyop/flow.rb` inside `ClassMethods#call`:

```ruby
def call(attrs = {})
  return _start_durable!(attrs) if _durable_flow?
  super   # => Operation.call → _easyop_run → CallBehavior#call
end
```

| Mode | `_durable_flow?` | `_persistent_flow_subject` | `.async` step | Returns |
|------|-----------------|---------------------------|---------------|---------|
| 1 — sync | false | nil | no | `Ctx` |
| 2 — fire-and-forget async | false | nil | yes | `Ctx` |
| 3 — durable | true | set | any | `FlowRun` |

`_durable_flow?` is true when any of the following hold:
1. `@_persistent_flow_subject` is set (own `subject` declaration).
2. `@_persistent_flow_compat` is true (set by `include Easyop::PersistentFlow` shim).
3. Any embedded sub-flow (recursively) has `_durable_flow? == true`.

### `_resolved_flow_steps` — recursive flatten

`ClassMethods#_resolved_flow_steps` builds the effective step list used by both
`CallBehavior#call` (Mode 1/2) and `Runner.advance!` (Mode 3). For durable
sub-flows, `_resolved_flow_steps` recurses into the sub-flow and splices its steps
inline. Mode-2 sub-flows stay as single entries.

Caching: the result is memoized in `@_resolved_flow_steps` on each class.

### `subject` precedence rule

`ClassMethods#_resolved_subject` returns the effective subject key:
1. Own `_persistent_flow_subject` first.
2. First durable sub-flow found by depth-first iteration of `_flow_steps`.

This key is used in `_start_durable!` to set `subject_type`/`subject_id` on the
`FlowRun` record.

### New error classes (v0.5)

| Constant | Location | When raised |
|----------|----------|-------------|
| `Easyop::Flow::DurableSupportNotLoadedError` | `flow.rb` | `subject` declared but `require "easyop/persistent_flow"` omitted |
| `Easyop::Flow::AsyncFlowEmbeddingNotSupportedError` | `flow.rb` | Whole flow class wrapped in `.async` (e.g. `Inner.async(wait:)`) |
| `Easyop::Flow::ConditionalDurableSubflowNotSupportedError` | `flow.rb` | `StepBuilder` modifier wraps a durable sub-flow |
| `Easyop::Operation::StepBuilder::PersistentFlowOnlyOptionsError` | `operation/step_builder.rb` | `.on_exception` / `.tags` / `.async(blocking: true)` used in a non-durable flow |

`AsyncStepRequiresPersistentFlowError` is kept for one release for backward-compat
`rescue` clauses — it is no longer raised internally.

### Step-builder DSL requires `plugin Easyop::Plugins::Async`

The class-level entry points `.async`, `.wait`, `.skip_if`, `.skip_unless`,
`.on_exception`, and `.tags` are installed by `Easyop::Plugins::Async`. An operation
class that does NOT have the plugin will raise `NoMethodError` if these methods are
called. Bare steps (no modifiers) do not require the plugin.

### Durable runner architecture (`lib/easyop/persistent_flow/runner.rb`)

`PersistentFlow::Runner` is a plain module (no instances). Two public entry points:

- **`Runner.advance!(flow_run)`** — starts or resumes a flow from
  `current_step_index`. Runs sync steps inline; for async steps, persists ctx to
  `context_data`, calls `Easyop::Scheduler.schedule_at(PerformStepOperation, run_at,
  { flow_run_id: })`, and returns (flow is suspended).
- **`Runner.execute_scheduled_step!(flow_run)`** — runs the step at
  `current_step_index` (invoked by `PerformStepOperation` when the Scheduler fires),
  then calls `advance!` to continue.

Key private helpers:
- `_execute_step!` — runs `instance._easyop_run(ctx, raise_on_failure: true)`;
  on `Ctx::Failure` calls `_halt_and_skip_remaining!`; on other exceptions calls
  `_apply_exception_policy!`.
- `_apply_exception_policy!` — calls `_resolve_retry_config` to determine max attempts;
  if more attempts remain, schedules the next retry via `Backoff.compute` + `Scheduler.schedule_at`;
  otherwise calls `_halt_and_skip_remaining!`.
- `_resolve_retry_config(step_class, step_opts)` — precedence: `:reattempt!` step opts
  → operation's `_async_retry_config` → default `{ max_attempts: 1 }`.
- `_halt_and_skip_remaining!(flow_run, failed_index, step_opts)` — sets
  `flow_run.status = 'failed'`; if `step_opts[:blocking]`, creates `'skipped'` rows for
  all remaining steps via `_mark_remaining_steps_skipped!`.
- `_persist_ctx` / `_rebuild_ctx` — serialize/deserialize ctx via
  `Easyop::Scheduler::Serializer`.

`Easyop::PersistentFlow::Backoff` (`persistent_flow/backoff.rb`) — pure stateless module.
`Backoff.compute(strategy, base, attempt)` returns delay in seconds.
Strategies: `:constant` (always `base`), `:linear` (`base * attempt`),
`:exponential` (`attempt⁴ + base + rand(30)`). Callable `base` is always called as `base.call(attempt)`.

---

## Architecture — key invariants

### `Ctx` is the single source of truth

`Easyop::Ctx` is a Hash-backed object (not OpenStruct) that serves as both the
input carrier and the result object. The same `ctx` instance is passed through
every step in a Flow and returned to the caller.

```ruby
ctx[:email]          # hash-style read
ctx.email            # method-style read (method_missing)
ctx.email?           # predicate — !!ctx[:email]
ctx.email = "x"      # method-style write
ctx.slice(:a, :b)    # returns plain Hash with only those keys
ctx.fail!(error: "…") # marks failed + raises Ctx::Failure (swallowed by .call)
```

### Operation execution model

```
Operation.call(attrs)
  └── new._easyop_run(Ctx.build(attrs), raise_on_failure: false)
        ├── @ctx = ctx
        └── _run_safe
              └── prepare { call }   ← user's call method runs here
                    ├── before hooks
                    ├── call
                    └── after hooks (in ensure)
```

`_run_safe` swallows `Ctx::Failure`; unhandled exceptions are caught by
`rescue_with_handler` if a matching `rescue_from` exists, otherwise re-raised
after marking ctx failed.

`_run_raising` (used by `.call!` and by `Flow` for each step) propagates
`Ctx::Failure` to the caller.

### `prepare` and the `&block` capture pattern

**Critical:** `prepare` must accept an explicit `&block` and call `block.call`
inside the inner proc. Using bare `yield` inside a proc does NOT delegate to the
enclosing method's block when the proc is called indirectly (e.g. through the
`call_through_around` chain). This was a fixed bug — do not revert.

```ruby
def prepare(&block)          # ← explicit block capture
  inner = proc do
    run_hooks(self.class._before_hooks)
    begin
      block.call                # ← block.call, never yield
    ensure
      run_hooks(self.class._after_hooks)
    end
  end
  call_through_around(self.class._around_hooks, inner)
end
```

### Flow MRO — why `CallBehavior` is prepended

When a class includes `Easyop::Flow`, the `included` hook calls
`base.include(Operation)`. This inserts Operation's modules into the ancestor
chain *before* Flow itself. Without intervention, `Operation#call` (a no-op)
would shadow `Flow#call`. The fix: extract flow's `call` logic into a nested
`Flow::CallBehavior` module and `base.prepend(CallBehavior)`. Prepend puts
`CallBehavior` before even the class itself, ensuring its `call` wins.

```
MRO after include Flow:
  [CallBehavior, ComputeSquare, Schema, Rescuable, Hooks, Operation, Flow, Object]
   ↑ wins for #call
```

### Rollback stores instances, not classes

`ctx.called!(instance)` stores the actual operation *instance* (not the class),
because `rollback` is an instance method that may need access to `ctx` via
`@ctx`. The Flow stores the instance created by `step.new`, which has `@ctx`
set by `_easyop_run`.

### Rescuable — child handlers first

`_rescue_handlers` stores only the class's *own* handlers. `_all_rescue_handlers`
returns own + parent handlers (in that order). This ensures child class handlers
always win over parent class handlers for the same exception class.

---

## Architecture — module responsibilities

| Module | Responsibility |
|--------|---------------|
| `Easyop::Ctx` | Context object: hash storage, fail!, callbacks, pattern matching |
| `Easyop::Hooks` | `before`/`after`/`around` DSL; `prepare` execution; hook inheritance |
| `Easyop::Rescuable` | `rescue_from` DSL; child-before-parent handler lookup |
| `Easyop::Skip` | `skip_if` DSL; `skip?` predicate called by Flow before each step |
| `Easyop::Schema` | `params`/`result` DSL; type validation before/after `call` |
| `Easyop::Operation` | Composes all modules; `call` / `call!` class methods; `_easyop_run` |
| `Easyop::FlowBuilder` | Accumulates `on_success`/`on_failure` callbacks; `bind_with`/`on`; `call` |
| `Easyop::Flow` | `flow` DSL; sequential step execution via `call!`; rollback on failure; automatically forwards `__recording_parent_*` ctx to steps for Recording plugin tree tracing |
| `Easyop::Events::Event` | Immutable frozen domain event value object |
| `Easyop::Events::Bus::Base` | Abstract adapter interface: `publish`, `subscribe`, `unsubscribe`; glob→regex helpers |
| `Easyop::Events::Bus::Adapter` | Inheritable base for custom buses; adds `_safe_invoke` + `_compile_pattern` (cached) |
| `Easyop::Events::Bus::Memory` | In-process synchronous bus; thread-safe via Mutex |
| `Easyop::Events::Bus::ActiveSupportNotifications` | Wraps `ActiveSupport::Notifications` |
| `Easyop::Events::Bus::Custom` | Wraps any user object with `#publish`/`#subscribe` |
| `Easyop::Events::Registry` | Global bus holder + thread-safe handler subscription registry |
| `Easyop::Plugins::Events` | Producer plugin: `emits` DSL; RunWrapper fires events in `ensure` |
| `Easyop::Plugins::EventHandlers` | Subscriber plugin: `on` DSL; registers at class-load time |
| `Easyop::Plugins::Recording` | Persists executions to AR model; flow tracing via `root_reference_id`/`reference_id`/`parent_*` columns (optional); `record_result` DSL for `result_data` output capture (optional); `filter_params` DSL + `filter_keys:` plugin option + global `recording_filter_keys` config for additive key filtering (values replaced with `[FILTERED]`) — all backward-compatible |

---

## Key classes — quick reference

### `Easyop::Ctx`

- `ctx.fail!(attrs = {})` — merges attrs, sets `@failure = true`, raises `Ctx::Failure`
- `ctx.success?` / `ctx.ok?` — `true` unless `fail!` was called
- `ctx.failure?` / `ctx.failed?` — `true` after `fail!`
- `ctx.error` — `ctx[:error]` shortcut
- `ctx.errors` — `ctx[:errors] || {}`
- `ctx.slice(:a, :b)` — plain Hash with only requested keys
- `ctx.on_success { |c| }` / `ctx.on_failure { |c| }` — post-call chainable callbacks
- `ctx.called!(instance)` — registers an instance for rollback
- `ctx.rollback!` — calls `rollback` on registered instances in reverse order, swallows errors
- `ctx.deconstruct_keys(keys)` — pattern matching support: `{ success:, failure:, **attrs }`

### `Easyop::Operation` (class methods)

- `call(attrs = {})` — returns ctx, never raises on `fail!`
- `call!(attrs = {})` — returns ctx on success, raises `Ctx::Failure` on `fail!`

### `Easyop::Flow` (class methods)

- `flow StepA, StepB, ...` — declare the ordered step list
- `flow ->(ctx) { condition }, Step` — lambda guard before a step
- `prepare` — returns a `FlowBuilder` for pre-registering callbacks

### `Easyop::FlowBuilder`

- `.on_success { |ctx| }` — register success callback; returns self
- `.on_failure { |ctx| }` — register failure callback; returns self
- `.bind_with(obj)` — bind an object for symbol-based callbacks
- `.on(success: :method, fail: :method)` — symbol callback shorthand
- `.call(attrs = {})` — execute flow, fire callbacks, return ctx

### `Easyop::Skip` (DSL on Operation)

- `skip_if { |ctx| boolean }` — declare when this step should be bypassed by Flow

---

## Configuration

```ruby
Easyop.configure do |c|
  c.strict_types = false  # true = ctx.fail! on schema type mismatch; false = warn
end
```

---

## Adding a new feature — checklist

1. **Write the test first** in `test/easyop/<feature>_test.rb`.
2. Implement in `lib/easyop/<feature>.rb`.
3. Require the new file in `lib/easyop.rb` in the correct load order (before
   modules that depend on it; after modules it depends on).
4. If it's a new public API, document it in `llms/overview.md`, `llms/usage.md`,
   and update `README.md` and `PROPOSAL.md`.
5. Add an example to `examples/usage.rb` and verify `ruby -Ilib examples/usage.rb` passes.
6. Run `bundle exec rake test` and confirm 0 failures.

---

## Things to never do

| Don't | Why |
|-------|-----|
| Use bare `yield` inside a `proc` in `prepare` | Doesn't reach the enclosing method's block when called indirectly; use `block.call` |
| Add a `call` instance method directly to `Easyop::Flow` | Gets shadowed by `Operation#call` (no-op) due to MRO; use `CallBehavior` + `prepend` |
| Store step classes (not instances) in `ctx.called!` | `rollback` is an instance method; must store instance with `@ctx` set |
| Put child rescue handlers after parent handlers in `_rescue_handlers` | Child handlers would never match for shared exception classes |
| Use `yield` inside `around` hooks | Around hooks receive a `callable` argument — call `inner.call` not `yield` |
| Mutate `_before_hooks` / `_after_hooks` arrays from a subclass | Always dup the parent's array first (already handled by `_inherited_hooks`) |
| Call `flow` with no args to get a builder | Use `prepare` — `flow` is only for declaring steps |
| Assume `ctx.some_key?` raises for missing keys | It returns `false` for keys not in `@attributes` (implemented in `method_missing`) |

---

## Dependencies

| Gem | Version | Why |
|-----|---------|-----|
| `minitest` | `~> 5.25` | Dev: test framework |
| `simplecov` | `~> 0.22` | Dev: coverage reporting |

No runtime dependencies beyond Ruby stdlib.

---

## Test conventions

- Test class: `FeatureTest < Minitest::Test`, include `EasyopTestHelper`
- Test methods: `def test_<snake_case_description>`; embed the method under test: `test_dot_call_...`
- Use `setup` / `teardown` for shared state; call `super` first/last
- Use the most specific assertion: `assert_predicate`, `assert_equal`, `assert_raises`, etc.
- Anonymous classes inline (`Class.new { include Easyop::Operation }`) are
  preferred for isolation — no top-level test class pollution
- Register named constants with `set_const('MyOp', klass)` — cleaned up automatically in `teardown`
- Group related tests with comment banners: `# ── rollback ────`
- Test names describe exact behaviour: `test_calls_rollback_in_reverse_order_on_failure`
- Coverage target: ≥ 88% line coverage
