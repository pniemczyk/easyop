# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/pniemczyk/easyop/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/pniemczyk/easyop/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/pniemczyk/easyop/compare/v0.1.2...v0.1.3
