# EasyOp — Claude Code Plugin

A Claude Code plugin that teaches Claude how to use the `easyop` gem to build
composable, testable operation objects in any Ruby or Rails project.

## What's Included

```
claude-plugin/
├── .claude-plugin/
│   └── plugin.json                            # Plugin metadata
├── easyop.skill                               # Packaged skill — install this
└── skills/
    └── easyop/
        ├── SKILL.md                           # Core skill — auto-loaded when relevant
        ├── references/
        │   ├── ctx.md                         # Ctx API reference
        │   ├── operations.md                  # Operation DSL (hooks, rescue, schema)
        │   ├── flow.md                        # Flow + FlowBuilder reference
        │   ├── hooks-and-rescue.md            # Hooks and rescue_from deep-dive
        │   └── plugins.md                     # All plugins reference
        └── examples/
            ├── basic_operation.rb             # Single operation patterns
            ├── flow.rb                        # Flow composition patterns
            ├── rails_controller.rb            # Rails controller integration
            ├── plugins.rb                     # Plugin usage examples
            └── testing.rb                     # RSpec test patterns
```

## Installing the Skill

### Option A — Install from the `.skill` file (recommended)

```bash
claude skills install path/to/easyop/claude-plugin/easyop.skill
```

### Option B — Install globally from the directory

```bash
claude --plugin-dir path/to/easyop/claude-plugin
```

### Option C — Copy into your project

```bash
cp -r path/to/easyop/claude-plugin/skills your-project/
cp -r path/to/easyop/claude-plugin/.claude-plugin your-project/
```

Then commit both `skills/` and `.claude-plugin/` to your repo so every developer
on the team gets the skill automatically.

### Option D — Reference from `CLAUDE.md`

```markdown
## EasyOp
@path/to/easyop/claude-plugin/skills/easyop/SKILL.md
```

## How the Skill Activates

The skill automatically activates when you ask Claude things like:

- "Add an operation for [some business logic]"
- "Create a flow that runs [steps] in sequence"
- "How do I use `ctx.fail!`?"
- "Replace this service object with an EasyOp operation"
- "How do I register callbacks before calling a flow?"
- "Use `prepare` to handle success and failure in my controller"
- "Add `skip_if` to make this step optional"
- "How do I roll back when a flow step fails?"
- "Write specs for this operation"
- "How is EasyOp different from Interactor?"
- "Add instrumentation / recording / async / transactional plugin"
- "Build a custom plugin"

## What Claude Will Know

Once installed, Claude knows:

1. How to write operations with `include Easyop::Operation`
2. How to compose operations into flows with `include Easyop::Flow`
3. How to use `prepare` + `bind_with` in Rails controllers
4. How to declare `skip_if` for conditional steps
5. How to implement `rollback` on each step
6. How to write before/after/around hooks and `rescue_from` handlers
7. How to add and configure all four plugins (Instrumentation, Recording, Async, Transactional)
8. How to build a custom plugin inheriting from `Easyop::Plugins::Base`
9. How to write RSpec specs for operations and flows
