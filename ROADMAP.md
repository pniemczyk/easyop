# EasyOp Roadmap

Rough plan for where the project is going. Not a commitment — priorities shift.

---

## Next up

### Plugin template gem (`easyop-plugin-template`)

A GitHub template repository and starter gem that makes it trivial to build and publish
your own EasyOp plugin. The same template is used by the built-in generators so
`easyop generate plugin` and `rake easyop:generate:plugin` scaffold from it locally:

- Scaffold with `Plugins::Base` subclass, `RunWrapper`, and `ClassMethods` already wired
- Minimal test setup with a fake `Operation` class so the plugin can be tested without Rails (optional)
- Gemspec, CI workflow, and changelog template included
- README section explaining how to hook into the `_easyop_run` pipeline

```ruby
# After using the template:
class MyPlugin < Easyop::Plugins::Base
  def self.install(base, **options)
    base.prepend RunWrapper
    base.extend ClassMethods
  end

  module RunWrapper
    def _easyop_run
      # before
      super
      # after
    end
  end

  module ClassMethods
    # DSL methods added to the operation class
  end
end
```

---

## Planned

- **`easyop-ui`** (separate gem) — mountable Rails engine with:
  - Browse, inspect, and roll back `OperationLog` records
  - Workflow index: list all registered flows and operations
  - DAG visualization generated on the fly from the live composition (no pre-build step)

- **DAG composition** (in core) — operations themselves are the nodes; no parallel step registry
  - Branching (`if/else`, `case`, `loop`) and fan-out / join as composition primitives
  - Introspectable: walk the composition to enumerate structure without running it
  - State machine: durable workflow-instance model with a state column and explicit transitions
  - First-class metadata + AR relations (FKs to the subject of the workflow: user, order, etc.)
  - Pause / resume / wait-for-external-event; `OperationLog` remains the per-step audit trail

- **Scheduler** (in core) — scheduling on top of `easyop-async`
  - Cron / recurring schedules with persisted schedule records in DB
  - Retry + backoff DSL, idempotency keys, concurrency limits
  - A scheduled run still produces a normal `OperationLog` row so existing tooling keeps working

- **OpenTelemetry plugin** (in core) — `Plugins::OpenTelemetry`, span per operation, `trace_id` forwarded into the log

- **Testing helpers** (in core) — `Easyop::Testing` with `op_call`, `assert_op_success`, `assert_op_failure`, `assert_ctx_encrypted`, `stub_op`

- **Standalone `easyop` CLI** — generator commands and workflow visualization:
  - `easyop generate operation Users::Create`
  - `easyop generate flow Flows::ProcessOrder`
  - `easyop generate plugin MyPlugin` — scaffolds a plugin gem from the `easyop-plugin-template`
  - `easyop workflow visualize MyFlow` — prints an ASCII DAG of the flow's composition in the terminal
  - All generators also available as Rake tasks: `rake easyop:generate:operation`, `rake easyop:generate:flow`, `rake easyop:generate:plugin`

## Under consideration

- `dry-validation` schema adapter

---

## Versioning

`0.x` minor versions may include breaking changes with a deprecation notice in the prior release.
`1.0` will lock down the public DSL once the `Planned` gems land and the API stabilizes.
