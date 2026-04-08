# therapist

Diagnose and fix persistent behavioral issues in Claude sessions using a framework adapted from Cognitive Behavioral Therapy (CBT).

## What it does

When Claude repeatedly violates explicit rules despite clear instructions, the problem is usually not ignorance — it is a pattern of rationalization. This plugin bundles:

- **A `/therapist` slash command** and a `therapist` skill that walks through a full CBT intervention: diagnosis, reframe, behavioral experiment, and relapse prevention.
- **Ambient hooks** that catch common rationalization patterns live (at `Write`/`Edit`/`Bash` tool use) so bad reasoning is interrupted before it turns into bad code.
- **A reference toolbox** of 11 techniques (grounding, socratic, mirror, reframe, activate, pause, rubber-band, affirmation, etc.) invoked by the hooks or explicitly via the skill.

The plugin stores per-session state under `.therapist/` so analytics, journal entries, and graduation tracking persist across interventions.

## Commands

- `/therapist [behavior]` — run the skill against a described unwanted behavior.

## Hooks

- `SessionStart` — affirmation prime on startup / resume / clear / compact.
- `PreToolUse` on `Write|Edit` — rubber-band check for rationalization phrases.
- `PreToolUse` on `git commit`/`git push` — pause check before shared-state actions.
- `PostToolUse` on `Bash` — mirror, reframe, and background activate.
- `PostToolUse` on `Write|Edit` — socratic follow-up prompt.

All hooks resolve scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/*.sh` so the plugin is portable across install locations.

## Tests

`scripts/test_therapist.sh` (which sources `test_hooks_write.sh` and `test_hooks_bash.sh`), `scripts/test_lib.sh`, and `scripts/test_journal.sh` cover the library helpers, hook dispatch, and journal persistence.

## Source

Ported from `arqu-co/claude-skills` (`plugins/therapist`) into the `jerrod/axr` marketplace. The runtime behavior is unchanged — only packaging and the marketplace wrapper command are new.
