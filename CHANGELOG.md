# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] — Unreleased

### Added

- **`async_retry` macro on operation class** — declare Sidekiq-style retry policy once, on the operation that owns it. `plugin Easyop::Plugins::Async` now exposes `async_retry max_attempts:, wait:, backoff:` (`:constant`, `:linear`, `:exponential`, or callable). Inherited by subclasses. Mode-3 only; ignored in Mode-2 fire-and-forget flows.
- **`Op.async(blocking: true)` step flag** — when a Mode-3 async step exhausts its retries (or fails with `ctx.fail!`), `blocking: true` at the call site halts the flow and records every remaining step as `'skipped'` in `EasyFlowRunStep`, giving a complete audit trail. Raises `PersistentFlowOnlyOptionsError` in Mode-2 flows.
- **`Easyop::PersistentFlow::Backoff` module** — pure utility for computing retry delays: `:constant`, `:linear`, `:exponential` (with jitter), and callable strategies.
- **Precedence rule** — per-step `.on_exception(:reattempt!, max_reattempts: N)` overrides `async_retry` for that specific usage site; existing flows are unaffected.

- **Unified `Easyop::Flow` API** — `include Easyop::Flow` is now the only flow module. Three execution modes are auto-detected:
  - **Mode 1** (no `subject`, no `.async` step): pure sync → returns `Ctx`.
  - **Mode 2** (no `subject`, has `.async` step): sync + fire-and-forget → returns `Ctx`; each async step is enqueued via `klass.call_async` (ActiveJob) and the flow continues immediately to the next step. No AR or Scheduler dependency required.
  - **Mode 3** (`subject` declared): durable suspend-and-resume → returns `FlowRun`; async steps persist ctx and schedule re-entry via the DB scheduler.
- **`subject` is the only durability trigger.** An async step alone (without `subject`) is fire-and-forget (Mode 2), never durable. Requires `require "easyop/persistent_flow"` in the initializer; raises `Easyop::Flow::DurableSupportNotLoadedError` with a clear message otherwise.
- **Free composition** — any flow can embed operations *and* other flows in its `flow(...)` declaration:
  - Mode-1/Mode-2 sub-flows run as a single inline step sharing ctx with the outer flow.
  - Durable (subject-bearing) sub-flows are **flattened** into the outer's resolved step list via `_resolved_flow_steps`, auto-promoting the outer to Mode 3.
  - Wrapping a durable sub-flow in step modifiers (e.g. `Inner.skip_if { ... }`) raises `Easyop::Flow::ConditionalDurableSubflowNotSupportedError` — deferred to v0.6.
  - Wrapping an entire flow in `.async` (e.g. `Inner.async(wait: 1.day)`) raises `Easyop::Flow::AsyncFlowEmbeddingNotSupportedError` — deferred to v0.6.
- **`.call` returns two types by design:** `Ctx` for Modes 1 & 2, `FlowRun` for Mode 3.

### Changed

- **`Easyop::PersistentFlow` is now a deprecated shim.** `include Easyop::PersistentFlow` is equivalent to `include Easyop::Flow` (with backward-compat durable-mode forced on). Will be removed in v0.6.
- **`start!` is a deprecated alias for `.call`.** Both return `FlowRun` for durable flows.
- **Async steps in non-durable flows no longer raise.** Previously `AsyncStepRequiresPersistentFlowError` was raised; now they fire-and-forget via `call_async`. The error class is kept for one release for `rescue` compat.

## [0.4.0] — Unreleased

### Added

- **`Easyop::PersistentFlow`** — durable multi-step orchestration that survives process restarts. Opt-in: `require "easyop/persistent_flow"`.

  - `include Easyop::PersistentFlow` in any class that also declares a `flow` to get durable execution.
  - `subject :user` macro — binds a polymorphic AR reference to the flow run (`flow_run.subject`).
  - `start!(attrs)` class method — creates an `EasyFlowRun` row and begins execution immediately.
  - Sync steps run inline; async steps (`step.async`) are deferred via `Easyop::Scheduler` and executed by `Easyop::PersistentFlow::PerformStepOperation`.
  - Ctx is serialized between async boundaries using `Easyop::Scheduler::Serializer` (primitives + AR refs survive; non-serializable values drop silently — v0.5 will make this a contract).
  - `flow_run.cancel!`, `flow_run.pause!`, `flow_run.resume!` lifecycle controls.
  - `on_exception(:cancel!)` — fails the flow on any uncaught exception.
  - `on_exception(:reattempt!, max_reattempts: N)` — reschedules the failing step immediately and fails the flow after `N` total attempts.
  - `FlowRunModel` and `FlowRunStepModel` mixins for the generated AR models.
  - `Easyop::PersistentFlow::PerformStepJob` — optional ActiveJob entry point for queue adapters.
  - Generator support: `write_persistent_flow_migrations` and `write_persistent_flow_models` in `Easyop::Installer::Generator`.
  - **`Easyop::Testing::PersistentFlowAssertions`** — included automatically when `Easyop::PersistentFlow` is defined: `speedrun_flow(flow_run)`, `assert_flow_status`, `assert_step_completed`, `assert_step_skipped`, `assert_step_failed`.
  - New config attrs: `Easyop.config.persistent_flow_model` (default: `'EasyFlowRun'`), `Easyop.config.persistent_flow_step_model` (default: `'EasyFlowRunStep'`).
  - Migration templates: `easy_flow_runs_migration.rb.tt`, `easy_flow_run_steps_migration.rb.tt`.
  - Model templates: `flow_run_model.rb.tt`, `flow_run_step_model.rb.tt`.

## [0.3.0] — Unreleased

### Added

- **Fluent async API (`Easyop::Operation::StepBuilder`)** — chainable, immutable builder for configuring an operation as a flow step or standalone async enqueue. Created via class-level entry points added by `Easyop::Plugins::Async`:

  ```ruby
  # Standalone async enqueue
  Reports::GeneratePDF.async(wait: 5.minutes).call(report_id: 42)

  # Inside a flow declaration
  flow CreateUser,
       SendWelcomeEmail.async,
       SendNudge.async(wait: 1.day).skip_if { |ctx| !ctx[:newsletter] },
       RecordComplete
  ```

  - `Op.async(**opts)` — marks step as async, accepts `wait:`, `queue:`.
  - `Op.wait(duration)` — sets wait without async flag.
  - `Op.skip_if { |ctx| ... }` — skip when block returns truthy (flow use only).
  - `Op.skip_unless { |ctx| ... }` — skip when block returns falsy (flow use only).
  - `Op.on_exception(policy, **opts)` — exception policy (PersistentFlow use only).
  - `Op.tags(*list)` — additive tags (PersistentFlow use only).
  - `.call(attrs)` — enqueues async; raises `PersistentFlowOnlyOptionsError` if flow-only opts are set.
  - `.to_step_config` — returns frozen opts hash for the flow parser.
  - **Immutability**: each chain method returns a new instance; opts are frozen.
  - **Option accumulation**: scalars last-write-wins; `:tags` is additive.
  - **`Easyop::Flow`** extended to handle `StepBuilder` entries: evaluates `skip_if`/`skip_unless` guards inline; raises `AsyncStepRequiresPersistentFlowError` if an async step appears in a plain `Flow`.
  - **`Easyop::Testing#assert_step_builder(builder, expected)`** — verifies StepBuilder option values.

## [0.2.0] — Unreleased

### Changed

- **Minitest-only internal test suite** — dropped the internal RSpec suite (`spec/`). All coverage is now in `test/` using Minitest. `Easyop::Testing` continues to support both Minitest and RSpec for end users. Run the suite with `bundle exec rake test`.
- Removed `rspec` development dependency from `Gemfile` and `easyop.gemspec`.
- Fixed unqualified `Logger` constant in `Easyop::Plugins::Instrumentation.attach_log_subscriber` (now `::Logger`).

### Added

- **`Easyop::Testing` module** — single `include Easyop::Testing` wires all assertion sub-modules into Minitest or RSpec automatically. Works without ActiveSupport.

  - **`Easyop::Testing::Assertions`** — core operation helpers: `op_call`, `op_call!`, `assert_op_success`, `assert_op_failure` (with optional `error:` string/regexp), `assert_ctx_has`, and `stub_op` (works with both Minitest `Object#stub` and RSpec `allow().to receive()`).
  - **`Easyop::Testing::FakeModel`** — lightweight AR-compatible spy for the Recording plugin. Pass as `model:` to avoid writing to a real database. Exposes `last_params`, `last_result`, `params_at(i)`, `result_at(i)`, `records_for(name)`, `clear!`.
  - **`Easyop::Testing::RecordingAssertions`** — `assert_recorded_success`, `assert_recorded_failure`, `assert_params_recorded`, `assert_params_filtered`, `assert_params_encrypted`, `assert_params_not_encrypted`, `assert_result_recorded`, `assert_ar_ref_in_params`, `assert_ar_ref_in_result`, `decrypt_recorded_param`, `with_recording_secret`.
  - **`Easyop::Testing::AsyncAssertions`** — `capture_async`, `perform_async_inline`, `assert_async_enqueued`, `assert_no_async_enqueued`, `assert_async_queue`, `assert_async_wait`.
  - **`Easyop::Testing::EventAssertions`** — `capture_events`, `assert_event_emitted`, `assert_no_events`, `assert_event_payload`, `assert_event_source`, `assert_event_on`.

- **`Easyop::Scheduler`** — DB-backed scheduler for deferred and recurring operation execution. Opt-in: `require "easyop/scheduler"`.

  - `Easyop::Scheduler.schedule_at(MyOp, time, attrs, tags: [], dedup_key: nil)` — schedule an operation at an absolute time.
  - `Easyop::Scheduler.schedule_in(MyOp, duration, attrs, ...)` — schedule relative to now.
  - `Easyop::Scheduler.schedule_cron(MyOp, expression, attrs, ...)` — recurring schedule (requires `fugit` gem).
  - `Easyop::Scheduler.cancel(task_id)` / `cancel_by_tag(tag)` / `cancel_by_operation(klass)` — cancellation.
  - `Easyop::Scheduler.peek(filter)` — query pending tasks.
  - `Easyop::Scheduler::TickJob` — ActiveJob that calls `recover_stuck!` + `run_batch!`; uses `FOR UPDATE SKIP LOCKED` on PostgreSQL, optimistic locking elsewhere.
  - `Easyop::Scheduler::Serializer` — serialize/deserialize attrs across async boundaries (`__ar_class/__ar_id` convention for AR objects).
  - `Easyop::Plugins::Scheduler` — operation-level plugin adding `schedule_at`, `schedule_in`, `schedule_cron`, `schedule` class methods.
  - **`Easyop::Testing::SchedulerAssertions`** — included automatically when `Easyop::Scheduler` is defined: `assert_scheduled`, `assert_no_scheduled`, `flush_scheduler!`, `clear_scheduler!`.
  - New config attrs: `scheduler_model`, `scheduler_batch_size`, `scheduler_lock_window`, `scheduler_stuck_threshold`, `scheduler_default_max_attempts`, `scheduler_default_backoff`, `scheduler_dead_letter_callback`.
  - Migration template: `easy_scheduled_tasks_migration.rb.tt`. Model template: `easy_scheduled_task_model.rb.tt`. Generator methods: `write_scheduler_migration`, `write_scheduler_model`.

- **Code examples** — self-contained runnable scripts in `examples/code/` (01–07) covering operations, hooks, schemas, flows, events, and recording. Each file runs with plain `ruby examples/code/NN_name.rb` and uses in-memory stubs (no Rails, no database).

- **`Easyop::SimpleCrypt`** — new utility module wrapping `ActiveSupport::MessageEncryptor`. Provides `encrypt`, `decrypt`, `encrypted_marker?`, and `decrypt_marker` helpers. Raises `MissingSecretError` / `EncryptionError` / `DecryptionError`.

- **Five-step secret resolution chain** for `Easyop::SimpleCrypt.default_secret` (highest → lowest priority):
  1. `Easyop.config.recording_secret` — explicit code config
  2. `ENV["EASYOP_RECORDING_SECRET"]` — env var / Docker secret / CI
  3. `Rails.application.credentials.easyop.recording_secret` — nested Rails credentials namespace
  4. `Rails.application.credentials.easyop_recording_secret` — flat Rails credentials key
  5. `Rails.application.credentials.secret_key_base` — app fallback (dev/test out-of-the-box)

  The internal `_creds_dig` helper handles all common Rails credentials shapes: `ActiveSupport::EncryptedConfiguration`, `HashWithIndifferentAccess`, `OrderedOptions`, and plain `Hash` — including both symbol and string keys.

- **`encrypt_params` DSL for the Recording plugin** — per-class, inheritable, and stackable (mirrors `filter_params`). Values matched by the encrypt list are stored as `{ "$easyop_encrypted" => "<ciphertext>" }` marker hashes in `params_data` and `result_data`. Recoverable via `Easyop::SimpleCrypt.decrypt_marker`. Encryption failures store `"[ENCRYPTION_FAILED]"` and emit a warning — they never raise from the operation.

- **`encrypt_keys:` install option and `recording_encrypt_keys` global config** — plugin-level and application-level defaults for the encrypt list, equivalent to the class-level DSL.

- **Precedence rule** (highest wins): built-in `FILTERED_KEYS` → `"[FILTERED]"`; encrypt list → encrypted marker; user filter list → `"[FILTERED]"`; otherwise normal serialization.

- **Example app: `LogRollback` service** (`examples/easyop_test_app/app/services/log_rollback.rb`) — demonstrates building compensating transactions on top of Recording data. Walks a `root_reference_id` tree in reverse `execution_index` order, calling `klass.undo(log)` on each step. Supports `on_error: :raise | :collect | :halt`, `transaction:`, and `allow_partial:` options.

- **Example app: `Flows::PurchaseAccess`** — new demo flow showing `encrypt_params :credit_card_number` + `record_result attrs: %i[payment]` + `def self.undo(log)` that decrypts the card and issues a refund via a stub `RefundService`.

- **Example app: `Logs::UndoFromLog` operation** — thin wrapper around `LogRollback.undo!` that records the rollback itself as an `OperationLog` entry, giving admins a full audit trail of every rollback.

- **Example app: admin rollback UI** — the operation log show page now displays a "Rollback this flow" button for fully-successful trees, highlights encrypted params with a lock badge, and labels undoable steps.

## [0.1.7] — 2026-04-15

### Added

- **`execution_index` for `Easyop::Plugins::Recording`** — an optional `:integer` column that records the 1-based call order of each child operation within its parent. Root operations store `nil`. Each child's counter resets independently under its own parent, so siblings of different parents both start at `1`. Add via migration:

  ```ruby
  add_column :operation_logs, :execution_index, :integer
  add_index  :operation_logs, [:parent_reference_id, :execution_index],
             name: 'index_operation_logs_on_parent_ref_and_exec_index'
  ```

  Example tree:
  ```
  FullCheckout  (execution_index: nil — root)
    ValidateCart    (execution_index: 1)
    ApplyDiscount   (execution_index: 2)
      LookupCode    (execution_index: 1)  ← resets under new parent
      DeductAmt     (execution_index: 2)
    CreateOrder     (execution_index: 3)
  ```

  The column is fully optional and backward-compatible — missing columns are silently skipped.

## [0.1.6] — 2026-04-15

### Added

- **`record_result: true` form for `Easyop::Plugins::Recording`** — passing `true` at install time (or via the class-level `record_result true` DSL) now records the full ctx snapshot after the operation completes. `FILTERED_KEYS` are applied and `INTERNAL_CTX_KEYS` are excluded. The `true` form captures computed values set during `#call`, making it a full output snapshot.

- **`record_params` class-level DSL** — parallel to `record_result`, operations can now declare params recording behaviour per-class:

  ```ruby
  record_params false                          # disable params recording entirely
  record_params attrs: %i[email name]          # selective keys only
  record_params { |ctx| { id: ctx.user_id } }  # block form
  record_params :build_safe_params             # private method form
  record_params true                           # explicit full ctx (default)
  ```

  Inherited through the class hierarchy; subclasses can override.

- **`record_params:` install option extended** — the `plugin Easyop::Plugins::Recording, record_params:` option now accepts the same forms as the DSL: `false`, `true`, `{ attrs: }`, `Proc`, `Symbol`.

- **Input-only `params_data` by default** — when `record_params` is `true` (the default), `params_data` now records only the keys that were present in `ctx` **before** the operation body ran. Computed values written during `#call` are excluded from `params_data`. Custom forms (attrs/block/symbol) are user-controlled and evaluated after the call, so they can access computed values.

### Changed

- **`record_result` default is now `false`** — previously defaulted to `nil` (falsy). Explicit `false` makes intent clear and prevents accidental result logging.

## [0.1.5] — 2026-04-14

### Added

- **`filter_params` DSL for `Easyop::Plugins::Recording`** — declare additional params keys/patterns to filter in `params_data` on a per-class basis. Matched keys are kept but their value is replaced with `"[FILTERED]"`. Accepts `Symbol`, `String`, or `Regexp`. Additive with `FILTERED_KEYS` and never replaces the built-in list. Inherited by subclasses; any level of the hierarchy can override.

  ```ruby
  class ApplicationOperation < ...
    filter_params :api_token, /access.?key/i
  end

  class Orders::CreateOrder < ApplicationOperation
    filter_params :card_number   # stacks on top of parent's filter list
  end
  ```

- **`filter_keys:` option on `plugin Easyop::Plugins::Recording`** — supply a list of extra keys/patterns to filter at plugin install time. Inherited by all classes that share the same `plugin` declaration.

  ```ruby
  plugin Easyop::Plugins::Recording,
         model: OperationLog,
         filter_keys: [:stripe_token, /secret/i]
  ```

- **`Easyop::Configuration#recording_filter_keys`** — new global config key. Set once at boot and every recorded operation will filter these keys in addition to `FILTERED_KEYS` and any class-level declarations. Accepts `Symbol`, `String`, or `Regexp`.

  ```ruby
  Easyop.configure do |c|
    c.recording_filter_keys = [:api_token, /token/i]
  end
  ```

- **`[FILTERED]` value replacement** — sensitive keys are now kept in `params_data` with their value replaced by `"[FILTERED]"` instead of being removed entirely. This means audit logs show *which* sensitive fields were passed without exposing their values.

  **Filter precedence (all layers are additive):**
  1. `FILTERED_KEYS` — always applied (built-in list)
  2. `Easyop.config.recording_filter_keys` — global config
  3. `filter_keys:` plugin option + `filter_params` DSL — class hierarchy

- **`params_data` records only input keys by default** — `params_data` now snapshots the ctx keys present *before* the operation body runs. Values computed during `#call` (e.g. `ctx.user = User.create!(...)`) are excluded from `params_data`; use `record_result` to capture them. Custom `record_params` forms (attrs, block, symbol) are evaluated *after* the call and can access computed values when explicitly requested. FILTERED_KEYS and INTERNAL_CTX_KEYS are always excluded.

- **`record_result: true` form** — passing `true` records the full ctx snapshot (all non-internal keys, FILTERED_KEYS applied). Works at both the plugin install level and the class-level DSL.

  ```ruby
  # Plugin level — all operations inherit this default
  plugin Easyop::Plugins::Recording, model: OperationLog, record_result: true

  # Class level DSL
  class Orders::CreateOrder < ApplicationOperation
    record_result true
  end
  ```

- **`record_params` class-level DSL** — parallel to `record_result`, `record_params` can now be declared on any class to control what ends up in `params_data`. Supports four forms:

  ```ruby
  record_params false                            # disable params entirely
  record_params true                             # explicit full ctx (default)
  record_params attrs: :user_id                  # selective keys
  record_params attrs: [:user_id, :event_id]
  record_params { |ctx| { custom: ctx[:name] } } # block
  record_params :build_params                    # private method name
  ```

  FILTERED_KEYS are **always applied** to the extracted hash regardless of form (keys are kept, values replaced with `"[FILTERED]"`). Config is inheritable and overridable per subclass.

- **`record_params:` install option extended** — the plugin install-level `record_params:` option now accepts the same forms as the DSL: `Hash` (`{ attrs: }` ), `Proc`, and `Symbol`, in addition to `true`/`false`.

  ```ruby
  plugin Easyop::Plugins::Recording,
         model: OperationLog,
         record_params: { attrs: %i[user_id plan] }
  ```

### Changed

- **`record_result` default is now `false`** (was `nil`). Behaviour is identical — no `result_data` is written unless explicitly configured — but the default value is now consistent with the boolean-style `record_params: true` API convention.

## [0.1.4] — 2026-04-14

### Added

- **Flow-tracing forwarding in `Easyop::Flow`** — `CallBehavior#call` now automatically sets the `__recording_parent_*` ctx keys before running steps, so every child operation's log entry carries the flow class as its `parent_operation_name` and `parent_reference_id`. This works even when Recording is not installed on the flow class itself (bare `include Easyop::Flow`). When Recording IS installed (recommended: inherit from ApplicationOperation and add `transactional false`), the flow appears in the log as the root entry and RunWrapper handles the ctx setup — no double-setup occurs.

  ```ruby
  # Bare flow — Recording on steps only; flow itself is not recorded but
  # steps correctly show parent_operation_name: "Flows::Checkout"
  class Flows::Checkout
    include Easyop::Flow
    flow Orders::CreateOrder, Orders::ProcessPayment
  end

  # Recommended — flow is recorded as root, steps as children:
  class Flows::Checkout < ApplicationOperation
    include Easyop::Flow
    transactional false   # steps manage their own transactions
    flow Orders::CreateOrder, Orders::ProcessPayment
  end
  ```

  Result in operation_logs:
  ```
  Flows::Checkout         root=aaa  ref=bbb  parent=nil
    Orders::CreateOrder   root=aaa  ref=ccc  parent=Flows::Checkout/bbb
    Orders::ProcessPayment root=aaa  ref=ddd  parent=Flows::Checkout/bbb
  ```

- **`record_result` DSL for `Easyop::Plugins::Recording`** — selectively persist ctx output data into a new optional `result_data :text` column (stored as JSON). Supports three forms:

  ```ruby
  # Attrs form — one or more ctx keys
  record_result attrs: :invoice_id
  record_result attrs: [:invoice_id, :total]

  # Block form — custom extraction
  record_result { |ctx| { total: ctx.total, items: ctx.items.count } }

  # Symbol form — delegates to a private instance method
  record_result :build_result
  ```

  Plugin-level default (inherited by all subclasses):
  ```ruby
  plugin Easyop::Plugins::Recording, model: OperationLog, record_result: { attrs: :metadata }
  ```

  Class-level `record_result` overrides the plugin-level default. Missing ctx keys produce `nil` (no error). ActiveRecord objects are serialized as `{ id:, class: }`. Serialization errors are swallowed. The `result_data` column is silently skipped when absent from the model table — fully backward-compatible.

### Fixed

- **`Easyop::Schema` type-mismatch warning suppressed when `$VERBOSE` is `nil`** — `warn` is a no-op in Ruby when `$VERBOSE` is `nil` (e.g. when running under certain test setups or with `-W0`). Changed to `$stderr.puts` so the `[EasyOp]` type-mismatch message always reaches stderr regardless of Ruby's verbosity flag.

- **`Easyop::Schema` spec `strict_types` contamination across examples** — Setting `strict_types = true` inside an example without a corresponding teardown left the global config dirty for later examples. Added `after(:each) { Easyop.reset_config! }` at the top-level `RSpec.describe` so every example begins with a clean configuration.

- **`Easyop::Plugins::Instrumentation` flaky duration assertion** — The `:duration` payload is computed as `(elapsed_ms).round(2)`, which rounds to `0.0` for operations completing in under 0.005 ms. Relaxed the spec assertion from `be > 0` to `be >= 0` to reflect that a rounded-to-zero duration is a valid measurement, not an error.

## [0.1.3] — 2026-04-14

### Added

- **Minitest test suite** — a full parallel test suite covering all 21 modules in the gem. Tests live in `test/` and run via `bundle exec rake test` (or `bundle exec ruby -Ilib:test ...`). The suite complements the existing RSpec specs and is tracked as a separate SimpleCov report (command name `'Minitest'`).

  Coverage across 258 tests, 360 assertions:

  | Area | Files |
  |------|-------|
  | Core | `ctx_test`, `operation_test`, `hooks_test`, `rescuable_test`, `schema_test`, `skip_test`, `flow_test`, `flow_builder_test` |
  | Events infrastructure | `events/event_test`, `events/registry_test`, `events/bus/memory_test`, `events/bus/adapter_test`, `events/bus/custom_test`, `events/bus/active_support_notifications_test` |
  | Plugins | `plugins/base_test`, `plugins/recording_test`, `plugins/instrumentation_test`, `plugins/async_test`, `plugins/transactional_test`, `plugins/events_test`, `plugins/event_handlers_test` |

  Key test patterns: anonymous `Class.new` operations, `set_const` helper for named-constant scenarios (Recording, Async), shared stubs for `ActiveSupport::Notifications`, `ActiveRecord::Base`, `ActiveJob::Base`, and `String#constantize` — all in `test/test_helper.rb` so individual files stay focused.

- **`Rakefile`** — adds a `test` task (Minitest) as the default Rake task:

  ```ruby
  bundle exec rake test
  # or simply:
  bundle exec rake
  ```

- **`rake` gem** added to the `development/test` group in `Gemfile`.

- **`Easyop::Events::Bus::Adapter`** — a new inheritable base class for custom bus implementations. Subclass this instead of `Bus::Base` when building a transport adapter (RabbitMQ, Kafka, Redis, etc.). Provides two protected utilities on top of `Bus::Base`:

  - `_safe_invoke(handler, event)` — calls `handler.call(event)` and rescues `StandardError`, so one broken subscriber never prevents others from running
  - `_compile_pattern(pattern)` — converts a glob string or exact string to a `Regexp`, memoized per unique pattern per bus instance (glob→Regexp conversion happens only once regardless of publish volume)

  ```ruby
  require "easyop/events/bus/adapter"

  # Decorator: wrap any inner bus and add structured logging
  class LoggingBus < Easyop::Events::Bus::Adapter
    def initialize(inner = Easyop::Events::Bus::Memory.new)
      super(); @inner = inner
    end

    def publish(event)
      Rails.logger.info "[bus] #{event.name} payload=#{event.payload}"
      @inner.publish(event)
    end

    def subscribe(pattern, &block) = @inner.subscribe(pattern, &block)
    def unsubscribe(handle)        = @inner.unsubscribe(handle)
  end

  Easyop::Events::Registry.bus = LoggingBus.new

  # Full external broker example — RabbitMQ via Bunny gem:
  class RabbitBus < Easyop::Events::Bus::Adapter
    EXCHANGE_NAME = "easyop.events"
    def initialize(url = ENV.fetch("AMQP_URL")) = (super(); @url = url)
    def publish(event)
      exchange.publish(event.to_h.to_json, routing_key: event.name)
    end
    def subscribe(pattern, &block)
      q = channel.queue("", exclusive: true, auto_delete: true)
      q.bind(exchange, routing_key: pattern.gsub("**", "#"))
      q.subscribe { |_, _, body| _safe_invoke(block, decode(body)) }
    end
    private
    def decode(body) = Easyop::Events::Event.new(**JSON.parse(body, symbolize_names: true))
    def connection   = @conn ||= Bunny.new(@url).tap(&:start)
    def channel      = @ch   ||= connection.create_channel
    def exchange     = @exch ||= channel.topic(EXCHANGE_NAME, durable: true)
  end
  ```

- **`Plugins::Events`** — a new producer plugin that emits domain events after an operation completes. Install on any operation class and declare events with the `emits` DSL:

  ```ruby
  class PlaceOrder < ApplicationOperation
    plugin Easyop::Plugins::Events

    emits "order.placed", on: :success, payload: [:order_id, :total]
    emits "order.failed", on: :failure, payload: ->(ctx) { { error: ctx.error } }
    emits "order.attempted", on: :always
  end
  ```

  Options for `emits`: `on:` (`:success` / `:failure` / `:always`), `payload:` (Proc, Array of ctx keys, or nil for full ctx), `guard:` (optional Proc condition). Events fire in an `ensure` block so they are published even when `call!` raises `Ctx::Failure`. Individual publish failures are swallowed and never crash the operation. Subclasses inherit parent declarations.

- **`Plugins::EventHandlers`** — a new subscriber plugin that wires an operation as a domain event handler:

  ```ruby
  class SendConfirmation < ApplicationOperation
    plugin Easyop::Plugins::EventHandlers

    on "order.placed"

    def call
      OrderMailer.confirm(ctx.order_id).deliver_later
    end
  end

  # Async dispatch (requires Plugins::Async also installed):
  class IndexOrder < ApplicationOperation
    plugin Easyop::Plugins::Async, queue: "indexing"
    plugin Easyop::Plugins::EventHandlers

    on "order.*",      async: true
    on "inventory.**", async: true, queue: "low"

    def call
      SearchIndex.reindex(ctx.order_id)
    end
  end
  ```

  Supports glob patterns: `"order.*"` matches within one segment; `"order.**"` matches across segments. Registration happens at class-load time. Handler operations receive `ctx.event` (the `Easyop::Events::Event` object) and payload keys merged into ctx.

- **`Easyop::Events::Event`** — immutable, frozen domain event value object. Carries `name`, `payload`, `source` (emitting class name), `metadata`, and `timestamp`. Serializable to a plain Hash via `#to_h`.

- **`Easyop::Events::Bus`** — pluggable bus adapter system with three built-in adapters:
  - `Bus::Memory` — in-process synchronous bus (default). Thread-safe via Mutex. Supports glob patterns and Regexp subscriptions. Test-friendly: `clear!`, `subscriber_count`.
  - `Bus::ActiveSupportNotifications` — wraps `ActiveSupport::Notifications`. Lazy-checks for the library.
  - `Bus::Custom` — wraps any user object responding to `#publish` and `#subscribe`. Validates the interface at construction time.

- **`Easyop::Events::Registry`** — thread-safe global coordination point. Configure once at boot; handler subscriptions are registered against it at class-load time:

  ```ruby
  # Globally:
  Easyop::Events::Registry.bus = :memory           # default
  Easyop::Events::Registry.bus = :active_support
  Easyop::Events::Registry.bus = MyRabbitBus.new   # custom adapter

  # Or via config:
  Easyop.configure { |c| c.event_bus = :active_support }
  ```

- **`Easyop::Configuration#event_bus`** — new configuration key. Accepts `:memory`, `:active_support`, or a bus adapter instance.

## [0.1.2] — 2026-04-13

### Added

- **`Plugins::Async` — `queue` DSL** — a new `queue` class method for declaring the default queue directly on an operation class (or a shared base class). This lets subclasses override the queue set at plugin install time without re-declaring the plugin:

  ```ruby
  class Weather::BaseOperation < ApplicationOperation
    queue :weather   # all Weather ops use the "weather" queue
  end

  class Weather::FetchForecast < Weather::BaseOperation
    # inherits queue :weather automatically
  end

  class Weather::CleanupExpiredDays < Weather::BaseOperation
    queue :low_priority   # override just for this class
  end
  ```

  Accepts both `Symbol` and `String`. The setting is inherited by subclasses and can be overridden at any level of the hierarchy.

## [0.1.1] — 2026-04-01

### Fixed

- **`Plugins::Recording`** — operations executed as steps inside a `Flow` were not recorded on failure. Flows run each step with `raise_on_failure: true`, causing `Ctx::Failure` to propagate and skip the `.tap` block used to persist the log entry. Fixed by moving the persistence call into an `ensure` block so every execution — successful or failed — is always recorded.

## [0.1.0] — 2026-04-01

### Added

#### Core
- `Easyop::Operation` — core mixin; include in any Ruby class to get `call`, `call!`, `ctx`, hooks, rescue, and schema DSL
- `Easyop::Ctx` — shared context object that doubles as the result; supports `success?`, `failure?`, `fail!`, `called!`, `rollback!`, chainable `on_success`/`on_failure` callbacks, and Ruby 3+ pattern matching via `deconstruct_keys`
- `Easyop::Ctx::Failure` — exception raised by `call!` and propagated through flows; carries the failed `ctx`
- `Easyop::Hooks` — `before`, `after`, and `around` hook DSL; inheritable, no ActiveSupport dependency
- `Easyop::Rescuable` — `rescue_from ExceptionClass` DSL with block and `with: :method` shorthand; supports inheritance
- `Easyop::Schema` — optional typed `params` / `result` declarations (`required`, `optional`); aliased as `inputs`/`outputs`; type shorthands (`:integer`, `:string`, `:boolean`, `:float`, `:symbol`, `:array`, `:hash`) and custom class matching
- `Easyop::Skip` — `skip_if` DSL for conditional step execution inside flows
- `Easyop::Flow` — sequential operation chain with shared `ctx`; automatic rollback in reverse order on failure; supports lambda guards as inline steps and nested flows
- `Easyop::FlowBuilder` — fluent builder returned by `FlowClass.prepare`; supports `bind_with`, `on(success:, fail:)`, and direct `.call`

#### Plugins
- `Easyop::Plugins::Base` — abstract base class for custom plugins; defines the `self.install(operation_class, **options)` contract
- `plugin` DSL on `Operation::ClassMethods` — installs a plugin via `plugin PluginClass, **options`; inheritable by subclasses
- `Easyop::Plugins::Instrumentation` — emits `"easyop.operation.call"` events via `ActiveSupport::Notifications`; opt-in log subscriber via `attach_log_subscriber`
- `Easyop::Plugins::Recording` — persists every execution to an `OperationLog` ActiveRecord model; configurable `recording_model`; per-class opt-out with `recording false`; scrubs sensitive keys from persisted attrs
- `Easyop::Plugins::Async` — adds `.call_async` to any operation; serialises ActiveRecord objects as `{__ar_class:, __ar_id:}` and deserialises in the background job; lazy `Job` class creation avoids requiring ActiveJob at load time
- `Easyop::Plugins::Transactional` — wraps the full `before → call → after` lifecycle in an ActiveRecord (or Sequel) transaction; per-class opt-out with `transactional false`; inheritance-aware

#### Tooling
- `Easyop.configure` block — global configuration (`strict_types`, `recording_model`, `instrumentation_event_name`)
- `llms/overview.md` and `llms/usage.md` — LLM context files for AI-assisted development
- `claude-plugin/` — Claude Code skill with references and usage examples
- `examples/easyop_test_app/` — full Rails 8 blog application demonstrating all features in real-world code
- `examples/usage.rb` — 13 runnable plain-Ruby examples

[Unreleased]: https://github.com/pniemczyk/easyop/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/pniemczyk/easyop/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/pniemczyk/easyop/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/pniemczyk/easyop/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/pniemczyk/easyop/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/pniemczyk/easyop/compare/v0.1.2...v0.1.3
