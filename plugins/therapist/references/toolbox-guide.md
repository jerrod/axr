# CBT Toolbox Guide

Detailed reference for the CBT tools in the therapist skill. Each tool maps
a real CBT technique to a Claude Code enforcement mechanism.

## Tool Interactions (v2.0)

```
SessionStart ──> Affirmation Cards ──> reads Journal (trends + risk profile + downward arrow)
                                          ^
Write/Edit ────> Rubber Band ────────> logs to Journal (ABC + predictions + graduation)
  (pre)          Socratic ───────────> logs to Journal (code-signal questions)
  (post)                                  ^
Bash ──────────> Mirror ─────────────> logs to Journal (measurements + experiment outcomes)
               > Reframe ───────────> logs to Journal (+ decatastrophizing evidence)
               > Activate ──────────> logs to Journal (positive reinforcement, async)
                                          ^
git commit ────> Pause Button ───────> reads Journal (+ regression blocking)
                                          |
Manual ────────> Grounding Exercise    (standalone)
               > Exposure Deck         (reference)
               > Exemplars             (reference, project-specific)
```

The Journal is the central persistence layer. Tools that detect distortions write
to it; tools that provide feedback read from it. New in v2.0: the journal uses
ABC structure (Activating Event → Belief → Consequence), tracks predictions for
behavioral experiments, and records measurements for successive approximation.

---

## 1. The Rubber Band

**CBT technique:** Aversion interrupt — a mental "snap" when a harmful thought appears.

**Mechanism:** PreToolUse command hook on `Write|Edit`. Scans the content being
written for prohibited rationalization phrases.

**What it catches:**

| Phrase | Correction |
|--------|-----------|
| "pre-existing" | I own every file I touch |
| "close enough" | Run the tool. Read the number. |
| "out of scope" | If the user asked for it, it is in scope |
| "should be fine" | Run verification. Read the output. |
| "already broken" | If I touched it, I own it |
| "can be addressed later" | Fix it now if the file is in my diff |
| "not fixable" | Have I tried 3 approaches? Keep investigating. |

**Input:** JSON on stdin with `tool_input.content` (Write) or `tool_input.new_string` (Edit).

**Output:** `{"decision":"block","reason":"SNAP: ..."}` on match, or silent exit 0.

**Customization:** Edit the `PHRASES` associative array in `scripts/rubber-band.sh`
to add project-specific rationalization patterns.

### Graduation Model (v2.0)

The Rubber Band adapts its intervention intensity based on journal history,
tracked per distortion category:

| Incidents | Tier | Behavior |
|---|---|---|
| 0–4 | **Confront** | Blocks + supplies correction + one-line exemplar |
| 5–9 | **Question** | Blocks + cost-benefit analysis showing costs and benefits |
| 10+ | **Remind** | Allows (no block) + brief context reminder |

Categories: `ownership-avoidance`, `premature-closure`, `scope-deflection`,
`learned-helplessness`. See `references/common-distortions.md` for mappings.

### Behavioral Experiments (v2.0)

Every match also logs a `prediction` entry (resolved=false). When Mirror later
detects a gate result, it resolves the prediction and reports accuracy:

> "EXPERIMENT: Prediction accuracy 29% (2/7). Recent: coverage 87% X | 2 lint errors X | tests passed Y"

---

## 2. The Mirror

**CBT technique:** Reflection/confrontation — showing the person their actual behavior.

**Mechanism:** PostToolUse command hook on `Bash`. Detects quality command failures
and reflects specific numbers back.

**What it catches:**
- Coverage below 95% — reports the exact percentage and the gap
- Test failures — reports the count
- Lint violations — reports the count
- Any quality command failure

**Input:** JSON on stdin with `tool_input.command` and `tool_output`.

**Output:** JSON with `hookSpecificOutput.additionalContext` containing the reflection.
Only fires on quality-related commands (bin/test, bin/lint, pytest, etc.).

**Customization:** Edit the `is_quality_command` pattern in `scripts/mirror.sh` to
add project-specific quality tools.

### Successive Approximation (v2.0)

Mirror now tracks measurement history. When a metric improves between runs,
it reports progress instead of just failure:

> "THE MIRROR: Coverage is 78%. Progress: +16 points from 62%. Gap: 17 remaining."

When a metric regresses, it flags it explicitly and logs a regression entry
that blocks commits via the Pause Button:

> "REGRESSION: Coverage dropped from 78% to 72%."

### Behavioral Experiments (v2.0)

After detecting gate results, Mirror resolves any open predictions and
appends accuracy statistics to its output.

---

## 3. The Journal

**CBT technique:** Thought diary — recording incidents for pattern analysis.

**Mechanism:** CLI script with eight subcommands. All other tools log to the journal;
the journal provides the data for affirmations and trend analysis.

**Commands:**
- `journal.sh log <type> <trigger> <correction> [--phrase=X] [--source=Y] [--event=X] [--belief=X] [--consequence=X] [--category=X] [--predicted=X] [--resolved=X] [--metric=X] [--value=X] [--target=X] [--prediction-ts=X]`
- `journal.sh recent [N]` — show last N entries (default 10)
- `journal.sh stats` — distortion frequency counts
- `journal.sh streak` — days since last incident per type
- `journal.sh chain <category>` — downward arrow: session-grouped timeline
- `journal.sh abc [--group-by=event|belief|consequence]` — ABC analysis
- `journal.sh exemplar <category>` — three-tier exemplar lookup
- `journal.sh risk-profile` — risk assessment from journal patterns

**Storage:** `.therapist/journal.jsonl` in the repo root. Added to `.gitignore`
automatically. Each line is a JSON object with ABC fields: `ts`, `type`,
`trigger`, `phrase`, `correction`, `source`, `activating_event`, `belief`,
`consequence`, `category`, `predicted`, `resolved`, `metric`, `value`,
`target`, `prediction_ts`.

---

## 4. Affirmation Cards

**CBT technique:** Positive self-talk — reinforcing progress and flagging patterns.

**Mechanism:** SessionStart command hook. Reads journal history and generates a
personalized message based on trends.

**Message types:**
- **Fresh session** (no journal): reminds of standards
- **Improving** (fewer incidents this week vs. last): celebrates progress
- **Recurring** (same distortion firing repeatedly): warns about the specific type
- **Clean streak** (no incidents for multiple days): acknowledges discipline

**Output:** SessionStart JSON with `hookSpecificOutput.additionalContext`.

### Relapse Prevention (v2.0)

Affirmation now includes a forward-looking risk profile at session start,
identifying correlations between activating events and distortion categories:

> "RISK: premature-closure correlates with coverage tasks (6/8 = 75%).
> COPING: Run coverage tool immediately. Measure before forming opinions."

### Downward Arrow Auto-Trigger (v2.0)

When any category reaches 15+ all-time incidents, affirmation auto-runs
`journal.sh chain <category>` and includes a condensed root-cause analysis:

> "AUTO-DIAGNOSIS: premature-closure has 18 incidents. Root cause analysis: ..."

### Streak Tracking (v2.0)

Tracks consecutive clean sessions in `.therapist/streak.json` and reports
the streak at session start.

---

## 5. The Grounding Exercise

**CBT technique:** Reality testing — replacing subjective feelings with objective facts.

**Mechanism:** Standalone script, not a hook. Run manually during therapy sessions
or whenever "should be fine" thinking needs to be challenged.

**What it measures:**
- Line counts on recently modified files (flags those over 300)
- TODO/FIXME/HACK count across the project
- Available quality tools (bin/test, bin/lint, etc.)
- Lint error count (if bin/lint is available)

**Usage:** `bash scripts/grounding.sh`

**Output:** Formatted "reality check card" to stdout with measured facts.

---

## 6. The Pause Button

**CBT technique:** Impulse control — stopping to verify before acting.

**Mechanism:** PreToolUse command hook on `Bash(git commit*)` and `Bash(git push*)`.
Checks for objective evidence that verification was done.

**Evidence checks:**
1. `.quality/proof/` has files modified in the last 30 minutes
2. Journal entries today with `source=rubber-band` (flags unresolved snaps)
3. Staged source files have corresponding test files

**Output:** `{"decision":"block","reason":"PAUSE: ..."}` with a checklist of gaps,
or silent exit 0 if all evidence is present.

### Regression Blocking (v2.0)

Pause Button now also checks for metric regressions logged by Mirror. If any
metric regressed in the last hour, commit is blocked until the regression is fixed.

---

## 7. The Reframe

**CBT technique:** Cognitive reframing — shifting perspective on negative events.

**Mechanism:** PostToolUse command hook on `Bash`. Detects frustration patterns
and injects perspective shifts.

**Patterns detected:**
- **Repetition** (same command 3+ times): "Each error teaches something different.
  What changed between attempts?"
- **Impossibility** ("not found", "impossible" in output): "This constraint is
  information about what approach to try next."
- **Overwhelm** (output > 100 lines): "Read the FIRST error, not all of them.
  Fix one thing at a time."

**State:** Maintains `.therapist/cmd-history` for repetition tracking.

**Output:** JSON with `hookSpecificOutput.additionalContext` containing the reframe.

### Decatastrophizing (v2.0)

After the reframe message, the tool now appends an evidence layer from journal
history showing resolution rates for similar patterns:

> "EVIDENCE: You've encountered this pattern before. Resolution rate: 100% (4/4).
> The pattern says this is solvable."

On cold start (no history), it appends Socratic questions:
- Impossibility: "What specifically makes this impossible? Name the constraint."
- Repetition: "What's different about the error this time vs. last time?"
- Overwhelm: "How many *unique* errors are in this output? Usually it's 1-3 root causes."

---

## 8. Exposure Deck

**CBT technique:** Exposure therapy — controlled practice with triggering scenarios.

**Mechanism:** Reference file (`references/exposure-deck.md`) with 10 scenario cards.
Not executable — used during therapy sessions for structured practice.

**Cards cover:** minimization, authority diffusion, scope shrinking, premature closure,
optimism bias, complexity avoidance, mock substitution, impossibility declaration,
deferred action, proposal substitution.

**Each card provides:** setup, trigger, wrong response, correct response, practice prompt.

---

## 9. Socratic Questioning (v2.0)

**CBT technique:** Guided self-discovery — asking questions instead of supplying
answers, prompting the agent to identify the issue itself.

**Mechanism:** PostToolUse command hook on `Write|Edit`. Detects code-level
signals that suggest quality issues in what was just written.

**Signals detected:**
- `TODO`/`FIXME`/`HACK`/`XXX` markers in new code
- Internal mocks (`jest.mock`, `@patch`, `spyOn().mockImplementation`)
- Lint suppression markers (Python `no` + `qa`, `type: ignore`; JS/TS `eslint` + `-disable`, `@ts` + `-ignore`, `@ts` + `-expect-error`; generic `@suppress`) — see `scripts/socratic.sh` for the authoritative regex
- Broad exception handlers (`except:`, `except Exception:`)
- Oversized blocks (>50 lines in written content)

**Key design:** Never blocks. Only injects questions as `additionalContext`.
First match wins (one question per invocation). 5-minute cooldown.

**Output:** `{"hookSpecificOutput": {"additionalContext": "SOCRATIC: ...?"}}`

---

## 10. Behavioral Activation (v2.0)

**CBT technique:** Positive reinforcement — tracking and celebrating good behavior
to build intrinsic motivation, breaking the pure-punishment cycle.

**Mechanism:** PostToolUse command hook on `Bash` (async, non-blocking). Detects
when quality commands pass, especially proactive checks and recovery from failure.

**Positive signals:**
- **Proactive gate:** Quality command passes without a preceding commit attempt
- **Recovery:** Gate passes after a recent quality-failure journal entry

**Behavior:**
- 10-minute cooldown between activations
- Escalating brevity: verbose first, shorter after 5+ per session
- Tracks cross-session streaks in `.therapist/streak.json`

**Output:** `{"hookSpecificOutput": {"additionalContext": "ACTIVATION: ..."}}`

---

## 11. Custom Exemplars (v2.0)

**CBT technique:** Modeling/guided discovery — showing correct behavior by example.

**Mechanism:** Reference file (`references/exemplars.md`) with project-specific
examples of correct behavior, keyed by distortion category.

**Three-tier lookup:** `journal.sh exemplar <category>` searches:
1. Journal activation entries (dynamic, from real history)
2. Exposure deck scenarios (built-in, static)
3. Custom exemplars file (project-specific, manually curated)

Exemplars are appended as one-line evidence by Rubber Band (all tiers) and
Socratic Questioning.

---

## Troubleshooting

### Hooks not firing

Verify the hook entries are in `hooks/hooks.json` within the plugin directory. The
plugin system auto-discovers hooks from this file. Check that the matcher pattern
matches exactly.

### Journal not writing

Run `bash scripts/journal.sh log test "trigger" "correction"` manually. Check that
`.therapist/` exists and is writable. Verify `git rev-parse --show-toplevel` resolves
correctly from your working directory.

### Scripts fail with "command not found"

All scripts require `jq` and `python3` to be on the PATH. Install with your package
manager if missing. The `_lib.sh` shared library must be in the same directory as the
calling script.

### Pause Button blocks everything

The pause button requires `.quality/proof/` files from the last 30 minutes. If you
are not using the rq plugin's gate system, either remove the pause button hook or
adjust the `check_gate_proofs` function in `scripts/pause.sh`.

### Mirror and Reframe both fire on same command

This is by design. The Mirror provides factual reflection ("coverage is 87%") while
the Reframe provides cognitive reframing ("fix one thing at a time"). They serve
different therapeutic functions and do not conflict.
