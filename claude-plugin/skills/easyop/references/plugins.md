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

**Scrubbed keys** (never appear in `params_data`):
`:password`, `:password_confirmation`, `:token`, `:secret`, `:api_key`

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

**With Flow:** Applied per-step (each step gets its own transaction). For a flow-wide transaction, apply it to the Flow class itself.

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
