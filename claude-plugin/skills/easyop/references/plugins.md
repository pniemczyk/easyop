# EasyOp — Plugins Reference

Plugins extend the operation lifecycle. They are opt-in and require explicit loading.

## Activating Plugins

```ruby
# Activate on any operation class — subclasses inherit automatically:
class ApplicationOperation
  include Easyop::Operation

  plugin Easyop::Plugins::Instrumentation
  plugin Easyop::Plugins::Recording,    model: OperationLog
  plugin Easyop::Plugins::Async,        queue: "operations"
  plugin Easyop::Plugins::Transactional
end
```

`plugin` calls `PluginModule.install(self, **options)` and registers the plugin in `_registered_plugins`.

Also works with `include` style (Transactional supports both):
```ruby
include Easyop::Plugins::Transactional
```

## Plugin Execution Order

Plugins wrap `_easyop_run` via `prepend`. The last installed plugin is the outermost wrapper:

```
Transactional (outermost — last installed)
  Async::Job wrapping (not in the stack; Async only adds .call_async)
    Recording::RunWrapper
      Instrumentation::RunWrapper
        prepare { before → call → after }  (innermost)
```

## Plugin: Instrumentation

**Require:** `require "easyop/plugins/instrumentation"`

**Event:** `"easyop.operation.call"`

**Payload:**
| Key | Type | Notes |
|---|---|---|
| `:operation` | String | Class name |
| `:success` | Boolean | |
| `:error` | String \| nil | `ctx.error` on failure |
| `:duration` | Float | Milliseconds |
| `:ctx` | Ctx | The result object |

**Setup:**
```ruby
# Attach built-in log subscriber (call once in an initializer):
Easyop::Plugins::Instrumentation.attach_log_subscriber
# Output: "[EasyOp] Users::Register ok (4.2ms)"
# Output: "[EasyOp] Users::Authenticate FAILED (1.1ms) — Invalid email or password"

# Or subscribe manually:
ActiveSupport::Notifications.subscribe("easyop.operation.call") do |event|
  p = event.payload
  MyAPM.record(p[:operation], success: p[:success], ms: p[:duration])
end
```

## Plugin: Recording

**Require:** `require "easyop/plugins/recording"`

**Options:**
| Option | Default | |
|---|---|---|
| `model:` | required | ActiveRecord class |
| `record_params:` | `true` | Set `false` to skip params serialization |
| `record_result:` | `nil` | Plugin-level default for result capture (Hash/Proc/Symbol) |

**Required migration:**
```ruby
create_table :operation_logs do |t|
  t.string   :operation_name, null: false
  t.boolean  :success,        null: false
  t.string   :error_message
  t.text     :params_data          # JSON
  t.float    :duration_ms
  t.datetime :performed_at,   null: false
end
```

**Optional flow-tracing columns** — add these to reconstruct the full call tree:
```ruby
add_column :operation_logs, :root_reference_id,     :string
add_column :operation_logs, :reference_id,          :string
add_column :operation_logs, :parent_operation_name, :string
add_column :operation_logs, :parent_reference_id,   :string

add_index :operation_logs, :root_reference_id
add_index :operation_logs, :reference_id, unique: true
add_index :operation_logs, :parent_reference_id
```

When present, all operations in one execution tree share the same `root_reference_id`. Parent/child relationships are captured via `parent_operation_name` and `parent_reference_id`. Missing columns are silently skipped (backward-compatible).

`Easyop::Flow` automatically forwards these ctx keys to child steps. For the flow itself to appear in the tree as the root entry, inherit from your recorded base class and add `transactional false`:

```ruby
class ProcessCheckout < ApplicationOperation
  include Easyop::Flow
  transactional false  # steps manage their own transactions
  flow ValidateCart, ChargePayment, CreateOrder
end
```

| Column | Purpose |
|--------|---------|
| `root_reference_id` | UUID shared by every operation in one execution tree |
| `reference_id` | UUID unique to this operation execution |
| `parent_operation_name` | Class name of the direct calling operation |
| `parent_reference_id` | `reference_id` of the direct calling operation |

**`record_result` DSL** — persist selected ctx output to an optional `result_data :text` column (JSON):

```ruby
add_column :operation_logs, :result_data, :text

# Attrs form:
record_result attrs: :order_id
record_result attrs: [:charge_id, :amount_cents]

# Block form:
record_result { |ctx| { rows: ctx.rows.count, format: ctx.format } }

# Symbol form (private instance method):
record_result :build_result

# Plugin-level default (inherited by all subclasses):
plugin Easyop::Plugins::Recording, model: OperationLog,
       record_result: { attrs: :metadata }
```

Class-level `record_result` overrides the plugin default. Missing ctx keys → `nil`. AR objects → `{ "id" => 42, "class" => "User" }`. Serialization errors are swallowed. Column silently skipped when absent (backward-compatible).

**Scrubbed keys** (never appear in `params_data`):
`:password`, `:password_confirmation`, `:token`, `:secret`, `:api_key`

Internal tracing keys (`__recording_*`) are also excluded from `params_data`.

AR objects in ctx are serialized as `{ "id" => 42, "class" => "User" }`.

**Opt out:**
```ruby
class SensitiveOp < ApplicationOperation
  recording false
end
```

Recording errors are silently swallowed — a failed log write never breaks the operation.

## Plugin: Async

**Require:** `require "easyop/plugins/async"`

**Setup:**
```ruby
plugin Easyop::Plugins::Async, queue: "default"
```

**Enqueueing:**
```ruby
MyOp.call_async(attrs)                                  # default queue
MyOp.call_async(attrs, queue: "low")                    # override queue per call
MyOp.call_async(attrs, wait: 10.minutes)                # delay
MyOp.call_async(attrs, wait_until: Date.tomorrow.noon)  # scheduled
```

**`queue` DSL** — declare or override the default queue directly on a class without re-declaring the plugin. Accepts `Symbol` or `String`. Inherited by subclasses; can be overridden at any level:

```ruby
class Weather::BaseOperation < ApplicationOperation
  queue :weather   # all Weather ops use "weather" by default
end

class Weather::CleanupExpiredDays < Weather::BaseOperation
  queue :low_priority   # override at leaf level
end
```

Priority (highest → lowest): per-call `queue:` argument → `queue` DSL → `plugin ... queue:` option → `"default"`.

**Serialization:** ActiveRecord objects are serialized as `{ "__ar_class" => "User", "__ar_id" => 42 }` and re-fetched in the job. Only pass: `String`, `Integer`, `Float`, `Boolean`, `nil`, `Hash`, `Array`, or `ActiveRecord::Base`.

**Job class:** `Easyop::Plugins::Async::Job` — created lazily on first `.call_async`.

**Requires:** `ActiveJob::Base` (raises `LoadError` if not available).

## Plugin: Transactional

**Require:** `require "easyop/plugins/transactional"`

**Adapters:** ActiveRecord (detected first), Sequel. Raises if neither is defined.

**Usage:**
```ruby
# Via plugin DSL:
plugin Easyop::Plugins::Transactional

# Via include (classic):
include Easyop::Plugins::Transactional
```

**Opt out:**
```ruby
class ReadOnlyOp < ApplicationOperation
  transactional false
end
```

**Scope:** The transaction wraps the entire `prepare` chain — before hooks, call, and after hooks all run inside the same transaction. On `ctx.fail!`, the `Ctx::Failure` exception causes the transaction to roll back.

**With Flow:** Applied per-step (each step gets its own transaction). For a flow-wide transaction you could apply it to the Flow class itself, but when using Recording's flow tracing the recommended pattern is `transactional false` on the flow (steps own their transactions, EasyOp handles soft rollback).

## Plugin: Events (producer)

**Require:**
```ruby
require "easyop/events/event"
require "easyop/events/bus"
require "easyop/events/bus/memory"
require "easyop/events/registry"
require "easyop/plugins/events"
```

**Activate:**
```ruby
plugin Easyop::Plugins::Events
# Or with a per-class bus override:
plugin Easyop::Plugins::Events, bus: MyCustomBus.new
```

**`emits` DSL:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `on:` | `:success` / `:failure` / `:always` | `:success` | When to fire |
| `payload:` | `Proc`, `Array`, `nil` | `nil` (full ctx) | Event payload builder |
| `guard:` | `Proc`, `nil` | `nil` | Extra condition — fires only if truthy |

```ruby
class PlaceOrder < ApplicationOperation
  plugin Easyop::Plugins::Events

  emits "order.placed",    on: :success, payload: [:order_id, :total]
  emits "order.failed",    on: :failure, payload: ->(ctx) { { error: ctx.error } }
  emits "order.attempted", on: :always
  emits "vip.order",       on: :success, guard: ->(ctx) { ctx.total > 1_000 }
end
```

**Key behaviours:**
- Events fire in an `ensure` block — they publish even when `call!` raises `Ctx::Failure`
- Individual publish failures are rescued per-declaration and never crash the operation
- Declarations are inherited by subclasses (dup-from-parent pattern)
- `payload: [:a, :b]` calls `ctx.slice(:a, :b)` to build the hash
- `payload: nil` (default) passes `ctx.to_h` as the full payload
- `guard:` receives `ctx` — return a truthy value to allow the event

**`Easyop::Events::Event` — the event object:**

| Attribute | Description |
|-----------|-------------|
| `name` | String, frozen (e.g. `"order.placed"`) |
| `payload` | Frozen Hash |
| `source` | Emitting class name (String) |
| `metadata` | Frozen Hash (default `{}`) |
| `timestamp` | `Time` (auto-set if omitted) |

```ruby
event.to_h  # => { name:, payload:, source:, metadata:, timestamp: }
```

## Plugin: EventHandlers (subscriber)

**Require:** `require "easyop/plugins/event_handlers"`

**Activate:** `plugin Easyop::Plugins::EventHandlers`

**`on` DSL:**

```ruby
class SendConfirmation < ApplicationOperation
  plugin Easyop::Plugins::EventHandlers

  on "order.placed"                          # exact match
  on "order.*"                               # one-segment wildcard
  on "warehouse.**"                          # any-depth wildcard
  on "order.*", async: true                  # async dispatch (requires Async plugin)
  on "order.*", async: true, queue: "low"    # async with queue override
end
```

Registration happens **at class-load time** via `Easyop::Events::Registry.register_handler`.
Swapping the bus after handler classes load does **not** re-register existing subscriptions.

**Dispatch — what ctx receives:**

| Dispatch mode | `ctx.event` | Payload keys |
|---|---|---|
| Sync (default) | `Easyop::Events::Event` object | Merged directly into ctx |
| Async | not set | `ctx.event_data` (plain Hash) + payload keys |

```ruby
# Sync handler:
def call
  event = ctx.event        # Easyop::Events::Event
  order_id = ctx.order_id  # from event.payload
end

# Async handler:
def call
  data = ctx.event_data              # { name:, payload:, source:, ... }
  event = Easyop::Events::Event.new(**data.transform_keys(&:to_sym))
  SearchIndex.reindex(ctx.order_id)  # payload key also in ctx
end
```

**Glob pattern rules:**

| Pattern | Matches | Does not match |
|---|---|---|
| `"order.placed"` | `"order.placed"` | `"order.placed.v2"` |
| `"order.*"` | `"order.placed"`, `"order.failed"` | `"order.placed.v2"` |
| `"warehouse.**"` | `"warehouse.stock.low"`, `"warehouse.alert.fire.east"` | `"warehouse"` |

## Plugin: Events Bus

Configure once at boot before any `EventHandlers` classes are loaded:

```ruby
# config/initializers/easyop.rb

# Built-in options:
Easyop::Events::Registry.bus = :memory           # default — in-process, thread-safe
Easyop::Events::Registry.bus = :active_support   # ActiveSupport::Notifications

# Custom bus — subclass Bus::Adapter (see below) or pass a duck-typed object:
Easyop::Events::Registry.bus = MyRabbitBus.new

# Via configure block:
Easyop.configure { |c| c.event_bus = :active_support }
```

**Built-in adapters:**

| Adapter | Class | Notes |
|---|---|---|
| `:memory` | `Bus::Memory` | In-process, sync, thread-safe via Mutex. Default. |
| `:active_support` | `Bus::ActiveSupportNotifications` | Wraps `ActiveSupport::Notifications`. Raises `LoadError` if not available. |
| Any object | `Bus::Custom` | Wraps any object with `#publish` + `#subscribe`. Validated at construction. |

**Test helpers (Memory bus):**

```ruby
bus = Easyop::Events::Registry.bus   # Easyop::Events::Bus::Memory
bus.clear!                            # remove all subscriptions
bus.subscriber_count                  # Integer

# Or reset the whole registry between tests:
Easyop::Events::Registry.reset!
```

## Building a Custom Bus

Subclass `Easyop::Events::Bus::Adapter` to build a transport-backed bus.

**Require:** `require "easyop/events/bus/adapter"`

**Protected helpers inherited from `Adapter`:**

| Method | Description |
|---|---|
| `_safe_invoke(handler, event)` | Calls `handler.call(event)`, rescues `StandardError`. One broken handler never blocks others. |
| `_compile_pattern(pattern)` | Glob/string → `Regexp`, memoized per unique pattern string in this bus instance. |

**Private helpers inherited from `Bus::Base`:**

| Method | Description |
|---|---|
| `_pattern_matches?(pattern, name)` | True when `pattern` (glob String or Regexp) matches `name`. |
| `_glob_to_regex(glob)` | `"order.*"` → `/\Aorder\.[^.]+\z/`, `"order.**"` → `/\Aorder\..+\z/`. |

**Minimum contract:** implement `#publish(event)` and `#subscribe(pattern, &block)`. Override `#unsubscribe(handle)` if your transport supports cancellation.

**Example — logging decorator (no external deps):**

```ruby
require "easyop/events/bus/adapter"

class LoggingBus < Easyop::Events::Bus::Adapter
  def initialize(inner = Easyop::Events::Bus::Memory.new)
    super()
    @inner = inner
  end

  def publish(event)
    logger.info "[bus:publish] #{event.name} payload=#{event.payload}"
    @inner.publish(event)
  end

  def subscribe(pattern, &block) = @inner.subscribe(pattern, &block)
  def unsubscribe(handle)        = @inner.unsubscribe(handle)

  private

  def logger = defined?(Rails) ? Rails.logger : Logger.new($stdout)
end

Easyop::Events::Registry.bus = LoggingBus.new
```

**Example — RabbitMQ (Bunny gem):**

AMQP topic exchanges map cleanly to EasyOp globs: `*` is identical in both;
`**` (EasyOp) translates to `#` (AMQP).

```ruby
require "bunny"
require "json"
require "easyop/events/bus/adapter"

class RabbitBus < Easyop::Events::Bus::Adapter
  EXCHANGE_NAME = "easyop.events"

  def initialize(amqp_url = ENV.fetch("AMQP_URL", "amqp://guest:guest@localhost"))
    super()
    @amqp_url = amqp_url
    @mutex    = Mutex.new
    @handles  = {}
  end

  def publish(event)
    exchange.publish(
      event.to_h.merge(timestamp: event.timestamp.iso8601).to_json,
      routing_key: event.name, content_type: "application/json", persistent: false
    )
  end

  def subscribe(pattern, &block)
    queue = channel.queue("", exclusive: true, auto_delete: true)
    queue.bind(exchange, routing_key: _to_amqp_pattern(pattern))
    consumer = queue.subscribe(manual_ack: false) do |_d, _p, body|
      data  = JSON.parse(body, symbolize_names: true)
      event = Easyop::Events::Event.new(
                name: data[:name].to_s, payload: data.fetch(:payload, {}),
                metadata: data.fetch(:metadata, {}), source: data[:source],
                timestamp: data[:timestamp] ? Time.parse(data[:timestamp].to_s) : Time.now
              )
      _safe_invoke(block, event)
    end
    handle = Object.new
    @mutex.synchronize { @handles[handle.object_id] = { queue:, consumer: } }
    handle
  end

  def unsubscribe(handle)
    @mutex.synchronize do
      e = @handles.delete(handle.object_id); return unless e
      e[:consumer].cancel; e[:queue].delete
    end
  end

  def disconnect
    @mutex.synchronize { @connection&.close; @connection = @channel = @exchange = nil; @handles.clear }
  end

  private

  # EasyOp "**" → AMQP "#", EasyOp "*" → AMQP "*" (same semantics)
  def _to_amqp_pattern(p) = p.is_a?(Regexp) ? p.source : p.gsub("**", "#")
  def connection = @connection ||= Bunny.new(@amqp_url, recover_from_connection_close: true).tap(&:start)
  def channel    = @channel    ||= connection.create_channel
  def exchange   = @exchange   ||= channel.topic(EXCHANGE_NAME, durable: true)
end

# config/initializers/easyop.rb
Easyop::Events::Registry.bus = RabbitBus.new
at_exit { Easyop::Events::Registry.bus.disconnect }
```

**Duck-typed adapter (no subclassing):** pass any object with `#publish` + `#subscribe` directly.
The Registry auto-wraps it in `Bus::Custom`:

```ruby
Easyop::Events::Registry.bus = MyExistingBusObject.new
```

## Building a Custom Plugin

A plugin is any object responding to `.install(base_class, **options)`. Inherit from `Easyop::Plugins::Base`:

```ruby
require "easyop/plugins/base"

module TimingPlugin < Easyop::Plugins::Base
  def self.install(base, threshold_ms: 500, **_opts)
    base.prepend(RunWrapper)
    base.extend(ClassMethods)
    base.instance_variable_set(:@_timing_threshold_ms, threshold_ms)
  end

  module ClassMethods
    def timing(enabled); @_timing_enabled = enabled; end

    def _timing_enabled?
      return @_timing_enabled if instance_variable_defined?(:@_timing_enabled)
      superclass.respond_to?(:_timing_enabled?) ? superclass._timing_enabled? : true
    end

    def _timing_threshold_ms
      @_timing_threshold_ms ||
        (superclass.respond_to?(:_timing_threshold_ms) ? superclass._timing_threshold_ms : 500)
    end
  end

  module RunWrapper
    def _easyop_run(ctx, raise_on_failure:)
      return super unless self.class._timing_enabled?
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super.tap do
        ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        if ms > self.class._timing_threshold_ms
          Rails.logger.warn "[SLOW] #{self.class.name} took #{ms.round(1)}ms"
        end
      end
    end
  end
end

# Activate:
class ApplicationOperation
  include Easyop::Operation
  plugin TimingPlugin, threshold_ms: 200
end

# Opt out on a specific class:
class FastOp < ApplicationOperation
  timing false
end
```

**Naming conventions:**
- Prefix all internal instance methods with `_pluginname_` (e.g. `_timing_enabled?`)
- Use `instance_variable_defined?` (not `defined?`) to check instance variables on class objects — this correctly handles `false` values
- Always call `super` in `RunWrapper#_easyop_run` and return `ctx`
- Inherit from `Plugins::Base` for documentation clarity

**`_registered_plugins` inspection:**
```ruby
ApplicationOperation._registered_plugins
# => [{ plugin: Easyop::Plugins::Instrumentation, options: {} },
#     { plugin: Easyop::Plugins::Recording, options: { model: OperationLog } },
#     ...]
```
