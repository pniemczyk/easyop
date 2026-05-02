# Bump Version

Perform a full version bump for the easyop gem. Follow all steps in order — do not skip any.

## Steps

### 1. Bump `Easyop::VERSION`

- Edit `lib/easyop/version.rb` — increment the patch, minor, or major segment as appropriate (default: patch unless told otherwise).
- Ask the user which version segment to bump if not specified.

### 2. Run the full test suite

Run the full test suite and confirm zero failures before continuing:

```bash
bundle exec rake test
```

Fix any failures before moving to the next step.

### 3. Verify example apps contain usage examples

Check that the two example apps reference real usage of the gem:

- `example_apps/easyop_test_app/` — general operations/flows
- `example_apps/ticketflow/` — real-world flow with Recording plugin

If the new version introduced new features, confirm the example apps demonstrate them (or note what's missing).

### 4. Update documentation (if needed)

Update every file that references the version number or describes the plugin's behaviour. Check each file and update only what changed:

- `README.md` — version badge, feature descriptions
- `AGENTS.md` — agent guidance, feature list
- `CHANGELOG.md` — promote `[Unreleased]` section to `[X.Y.Z] — YYYY-MM-DD`, add a new empty `[Unreleased]` section at the top, add footer link
- `llms/overview.md` — high-level feature overview
- `llms/usage.md` — usage patterns
- `docs/*.html` — version references in all HTML docs (use `grep -rl` to find them)
- `claude-plugin/skills/easyop/SKILL.md` — `version:` field
- `claude-plugin/skills/easyop/references/plugins.md` — plugin reference docs
- `claude-plugin/skills/easyop/examples/plugins.rb` — plugin examples

### 5. Rebuild and validate `claude-plugin/easyop.skill`

Rebuild the skill ZIP from the correct working directory so entry paths are correct:

```bash
cd claude-plugin/skills && zip -r ../easyop.skill easyop/ -x "*.DS_Store"
```

Then verify the ZIP contents look correct (no `skills/` prefix in paths, explicit directory entries present):

```bash
unzip -l claude-plugin/easyop.skill | head -30
```

Confirm entries like `easyop/`, `easyop/SKILL.md`, `easyop/references/`, `easyop/examples/` are present without any `skills/` prefix.

## Done

Report the new version number and a summary of what was updated.
