# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/pniemczyk/easyop/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/pniemczyk/easyop/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/pniemczyk/easyop/releases/tag/v0.1.0
