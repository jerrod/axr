---
name: therapist
description: >
  This skill should be used when the user reports that Claude is "misbehaving",
  "ignoring rules", "not following instructions", "keeps doing X despite being told not to",
  "won't stop doing X", "is broken", "needs fixing", or any complaint about Claude's
  behavioral patterns. Also triggers on "therapist", "diagnose", "why does Claude keep",
  "CBT", "cognitive distortion", or "fix Claude's behavior".
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
argument-hint: "[describe the unwanted behavior]"
---

# Therapist

Diagnose and fix persistent behavioral issues in Claude sessions using a framework
adapted from Cognitive Behavioral Therapy. When Claude repeatedly violates explicit
rules despite clear instructions, the problem is not ignorance — it is a pattern
of rationalization that needs targeted intervention.

## Core Concept

Claude's behavioral failures follow predictable patterns analogous to cognitive
distortions in CBT. The model "knows" the rules (they are in context) but generates
rationalizations that override them. Treatment requires:

1. **Identifying the distortion** — what rationalization pattern is active
2. **Tracing the trigger** — what context or task activates it
3. **Finding the gap** — where rules/memories fail to prevent it
4. **Crafting the intervention** — a targeted correction that blocks the specific rationalization
5. **Persisting the fix** — saving the intervention so it survives across sessions

## CBT Toolbox

Executable tools that catch and correct distortions in real-time. Each maps
a real CBT technique to a Claude Code enforcement mechanism.

| # | Tool | Technique | Mechanism | Script |
|---|------|-----------|-----------|--------|
| 1 | The Rubber Band | Aversion interrupt + graduation | PreToolUse hook with adaptive intensity (confront→question→remind) | `scripts/rubber-band.sh` |
| 2 | The Mirror | Reflection + successive approximation | PostToolUse hook reflects failures with progress tracking | `scripts/mirror.sh` |
| 3 | The Journal | Thought diary + ABC model | Persistent JSONL log with structured ABC fields | `scripts/journal.sh` |
| 4 | Affirmation Cards | Positive self-talk + relapse prevention | SessionStart hook with risk profiles and coping strategies | `scripts/affirmation.sh` |
| 5 | The Grounding Exercise | Reality testing | Standalone script that measures facts vs. feelings | `scripts/grounding.sh` |
| 6 | The Pause Button | Impulse control + regression blocking | PreToolUse hook on git commit/push, blocks on regressions | `scripts/pause.sh` |
| 7 | The Reframe | Cognitive reframing + decatastrophizing | PostToolUse hook with resolution evidence from history | `scripts/reframe.sh` |
| 8 | Exposure Deck | Exposure therapy | Reference cards with triggering scenarios for practice | `references/exposure-deck.md` |
| 9 | Socratic Questioning | Guided self-discovery | PostToolUse hook on Write/Edit detects code-level signals | `scripts/socratic.sh` |
| 10 | Behavioral Activation | Positive reinforcement | PostToolUse hook (async) celebrates proactive checks | `scripts/activate.sh` |
| 11 | Custom Exemplars | Modeling / guided discovery | Three-tier exemplar lookup (journal→deck→custom) | `references/exemplars.md` |

See `references/toolbox-guide.md` for detailed documentation on each tool.

**Hooks are auto-discovered** from `hooks/hooks.json` — no manual installation needed.

## Diagnostic Protocol

### Phase 1: Intake

Gather the complaint from the user:
- What specific behavior is Claude exhibiting?
- How frequently does it occur?
- What was Claude doing when it happened?
- What should Claude have done instead?

If the user provides a clear description (e.g., "Claude keeps saying pre-existing"),
skip to Phase 2 without further questions.

### Phase 2: Context Scan

Systematically scan ALL sources of behavioral influence. Use `scripts/scan-context.sh`
to automate the search, or scan manually in this order:

1. **Global CLAUDE.md** — `~/.claude/CLAUDE.md`
2. **Project CLAUDE.md** — `./CLAUDE.md` and any nested `.claude/` directories
3. **Loaded rules** — `.claude/rules/*.md` and `~/.claude/rules/*.md`
4. **Memories** — `~/.claude/projects/*/memory/MEMORY.md` and linked files
5. **Active skills** — any skills currently loaded in the session
6. **Hooks** — `settings.json` and any `hooks.json` files

For each source, search for:
- Rules that **directly address** the reported behavior
- Rules that **conflict** with each other (creating ambiguity the model exploits)
- Rules that are **vague** enough to allow rationalization
- **Absence** of rules where one is needed

### Phase 3: Distortion Identification

Match the behavior to a cognitive distortion pattern. Consult
`references/common-distortions.md` for the full catalog. Common patterns:

| Distortion | Example | Rationalization |
|---|---|---|
| Minimization | "This is pre-existing" | Downplays ownership to avoid work |
| Scope deflection | "Out of scope" | Reframes required work as optional |
| Premature closure | "Close enough" | Declares victory before criteria met |
| Authority diffusion | "Already broken" | Attributes fault to prior sessions |
| Optimism bias | "Should be fine" | Substitutes belief for verification |
| Learned helplessness | "Not fixable" | Declares impossibility without exhaustive investigation |

### Phase 4: Root Cause Analysis

Determine WHY the distortion persists despite rules. Common root causes:

1. **Rule exists but is buried** — instruction is present but lost among thousands of tokens
2. **Rule is abstract, not specific** — says "don't rationalize" but doesn't name the exact phrase
3. **Conflicting signals** — two rules or a rule + training prior point different directions
4. **Missing enforcement** — rule says what not to do but has no "instead, do X" guidance
5. **Training prior is strong** — the behavior is a deep default that requires active override
6. **Context window position** — critical rules are too far from where decisions are made

### Phase 4b: Downward Arrow (Root Cause Chaining)

For recurring patterns (5+ incidents in a category), trace the surface belief
to its core belief using the downward arrow technique:

1. Run `journal.sh chain <category>` to see the session-grouped timeline
2. Run `journal.sh abc --group-by=belief` to see which beliefs appear most
3. For the top belief, follow the chain:

```
Surface: "The coverage is close enough"
  └─ Why? → "Writing more tests would take too long"
     └─ Why does that matter? → "The user wants fast delivery"
        └─ Evidence? → Journal shows no user complaints about speed.
           Core belief: SPEED > CORRECTNESS (unsupported by evidence)
```

4. Map to core beliefs table in `references/common-distortions.md`
5. Design intervention targeting the core belief, not just the surface phrase

**Auto-trigger:** At 15+ incidents, affirmation.sh automatically surfaces a
condensed downward arrow analysis at session start. No manual invocation needed.

### Phase 5: Intervention Design

Design a targeted intervention based on the root cause. Effective interventions follow
the CBT pattern of **catch → challenge → replace**:

1. **Catch phrase** — the exact words/thoughts to intercept (e.g., "pre-existing")
2. **Challenge** — why this thought is wrong in this context
3. **Replacement behavior** — what to do instead, stated concretely

Interventions must be:
- **Specific** — name the exact phrase or behavior, not a category
- **Actionable** — state what TO DO, not just what to avoid
- **Self-contained** — effective without needing to recall other rules
- **Positioned for impact** — placed where Claude will encounter it at decision time

For recurring or severe distortions (Level 3+), escalate to the CBT Toolbox:
- Install the **Rubber Band** hook to block rationalization phrases in code
- Install the **Mirror** hook to reflect quality failures with hard numbers
- Install the **Pause Button** hook to require verification evidence before commits
- Run the **Grounding Exercise** to replace feelings with measurements
- Use the **Exposure Deck** for structured practice against specific triggers

### Phase 6: Persistence

Save the intervention to the appropriate persistence layer. The CBT Toolbox
provides an additional persistence mechanism: the **Journal** (`scripts/journal.sh`)
logs every distortion incident as JSONL, enabling the Affirmation Cards hook to
deliver data-driven progress feedback at session start.

Choose the right layer:

**For behaviors that apply across all projects:**
→ Save as a feedback memory in `~/.claude/projects/*/memory/`

**For behaviors specific to one project:**
→ Add to the project's CLAUDE.md or `.claude/rules/`

**For behaviors that need immediate reinforcement:**
→ Add to CLAUDE.md in a prominent position (Soul section or top of file)

Format the intervention as a feedback memory:

```markdown
---
name: distortion-[name]
description: Intervention for [specific behavior] — [catch phrase]
type: feedback
---

[Rule/correction statement]

**Why:** [What went wrong — the specific incident or pattern]
**How to apply:** [When this thought/phrase appears, do X instead]
```

### Phase 7: Verification

After persisting the intervention:

1. Ask the user to describe the scenario that triggers the behavior
2. Process the scenario with the intervention now loaded
3. Confirm the corrected behavior is produced
4. If the distortion persists, return to Phase 4 — the root cause was misidentified

## When Diagnosis Fails

If scanning reveals no obvious gap (rules are clear, specific, and prominent):

1. Check if the behavior occurs early in long conversations (context window position)
2. Check if the behavior correlates with specific task types (trigger-specific)
3. Check if multiple rules interact to create ambiguity
4. Consult `references/cbt-framework.md` for advanced intervention techniques

## Additional Resources

### Reference Files

- **`references/cbt-framework.md`** — Full CBT framework adapted for AI behavioral patterns,
  including advanced techniques for treatment-resistant distortions
- **`references/common-distortions.md`** — Complete catalog of known AI cognitive distortions
  with examples, root causes, and proven intervention templates

### Scripts

- **`scripts/scan-context.sh`** — Automated scan of all context sources for rules relevant
  to a specific behavioral complaint. Usage: `bash scripts/scan-context.sh "pre-existing"`
- **`scripts/journal.sh`** — Therapy journal CLI. Usage: `journal.sh log|recent|stats|streak`
- **`scripts/grounding.sh`** — Reality-check measurements. Usage: `bash scripts/grounding.sh`

## Compatibility with rq Plugin

The rq plugin registers hooks on the same matchers (`Write|Edit`, `Bash`,
`Bash(git commit*)`, `Bash(git push*)`). Therapist hooks are designed to complement
rq hooks, not replace them. When both plugins are enabled, rq's enforcement runs
alongside therapist hooks. The Pause Button's gate proof check reads rq's
`.quality/proof/` directory — the two are complementary.
