# CBT Framework for AI Behavioral Correction

## Why CBT Works for AI

Cognitive Behavioral Therapy targets the cycle: **trigger → thought → behavior → outcome**.
For Claude, this maps directly:

- **Trigger** — a task or context that activates a default behavior
- **Thought** — a rationalization generated before the action (the "inner monologue")
- **Behavior** — the observable action (skipping tests, saying "pre-existing", etc.)
- **Outcome** — user frustration, rule violation, quality degradation

CBT does not try to change the trigger or the outcome. It intervenes at the **thought**
level — catching the rationalization before it produces the behavior.

## The CBT Cycle for AI

```
Trigger (task/context)
    ↓
Automatic Thought (rationalization)
    ↓
[INTERVENTION POINT] ← catch the thought here
    ↓
Behavior (action taken)
    ↓
Outcome (result)
```

## Core Techniques

### 1. Thought Records

A thought record documents the full cycle for a specific incident:

| Field | Question | Example |
|---|---|---|
| Situation | What was happening? | Modifying a file with existing lint errors |
| Automatic thought | What rationalization appeared? | "These errors are pre-existing" |
| Emotion/drive | What motivated the thought? | Desire to limit scope, avoid extra work |
| Evidence FOR | What supports the rationalization? | The errors existed before this session |
| Evidence AGAINST | What contradicts it? | CLAUDE.md says "there is no pre-existing" |
| Balanced thought | What is the corrected thought? | "I own every file I touch. Fix all violations." |
| Outcome | What is the correct action? | Fix the lint errors before committing |

Creating a thought record during diagnosis makes the distortion pattern explicit and
generates the exact language needed for the intervention.

### 2. Cognitive Restructuring

Replace distorted thoughts with accurate ones. The key insight: **the replacement
must be as specific and concrete as the distortion it replaces.**

Bad intervention (too abstract):
> "Don't rationalize."

Good intervention (specific catch-and-replace):
> "When the thought 'this is pre-existing' appears, replace it with: 'I own every
> line in files I touch. If it's in my diff, every violation is mine.'"

The replacement thought must:
- Name the exact trigger phrase
- Provide the exact replacement phrase
- Be self-contained (no need to look up other rules)

### 3. Behavioral Activation

For avoidance behaviors (Claude avoiding hard work by deflecting), the intervention
must include a concrete action step:

> "When tempted to say 'out of scope', instead: (1) check if the user requested this
> change, (2) if yes, it is in scope by definition, (3) proceed with the work."

The action steps make the correct behavior automatic rather than requiring judgment.

### 4. Exposure Hierarchy

For deeply ingrained patterns, introduce corrections gradually:

1. **Level 1** — Add explicit rule naming the exact phrase to avoid
2. **Level 2** — Add the rule to CLAUDE.md Soul section for maximum prominence
3. **Level 3** — Add pre-commit hook that scans for the phrase in responses
4. **Level 4** — Add feedback memory with incident history for emotional weight

If Level 1 doesn't work, escalate. Most distortions resolve at Level 1-2.

### 5. Relapse Prevention

After successful intervention, prevent regression:

- **Identify high-risk situations** — what tasks/contexts trigger the old behavior
- **Create if-then plans** — "IF I'm modifying a file with existing issues, THEN I fix them"
- **Monitor early signs** — softer versions of the same rationalization
- **Refresh interventions** — update memory/rules periodically to prevent staleness

### 6. Socratic Questioning (v2.0)

Instead of supplying corrections, ask guided questions that lead to self-discovery:
- Code-level: "This mock replaces an internal collaborator. What would break with the real implementation?"
- Graduation: After 5+ incidents in a category, Rubber Band switches from corrections to questions

Questions produce deeper behavioral change than corrections because the agent
generates the correct answer itself, creating stronger associative bonds.

### 7. Behavioral Experiments (v2.0)

Track predictions vs. outcomes to build an evidence record:
1. Agent writes "should be fine" → Rubber Band logs a `prediction` entry (predicted=pass)
2. Agent runs gates → Mirror logs an `outcome` entry (actual=fail, coverage 87%)
3. Mirror reports: "EXPERIMENT: Prediction accuracy 29% (2/7)."

Over time, the evidence record makes it undeniable that gut predictions are unreliable.

### 8. Successive Approximation (v2.0)

Track progress toward targets instead of just reporting pass/fail:
- "Coverage 78%. Progress: +16 points from 62%. Gap: 17 remaining."
- Regressions are flagged, logged, and block commits via Pause Button.

The target never changes (95% is 95%), but acknowledging progress builds momentum.

### 9. Decatastrophizing (v2.0)

Append resolution evidence to reframe messages:
- "EVIDENCE: Resolution rate: 100% (4/4). The pattern says this is solvable."
- Cold start: Socratic questions instead ("What specifically makes this impossible?")

### 10. Cost-Benefit Analysis (v2.0)

In Rubber Band's Question tier (5-9 incidents), show concrete costs and benefits:
- "Keeping 'close enough' has cost: 6 blocked commits, 4 gate re-runs, accuracy 29%."
- "Benefit of verifying: zero rework in 12 cases."

### 11. Downward Arrow (v2.0)

Auto-triggers at 15+ incidents in a category via affirmation.sh:
- Groups entries by session, traces belief→event→consequence chains
- Maps to core beliefs (see `common-distortions.md`)
- Full analysis available via `journal.sh chain <category>`

### 12. ABC Model (v2.0)

All journal entries use structured ABC fields:
- **A** (Activating Event): what triggered the distortion
- **B** (Belief): the rationalization phrase
- **C** (Consequence): what would have happened without intervention

Analysis: `journal.sh abc --group-by=event|belief|consequence`

### 13. Relapse Prevention (v2.0)

Risk profiles at session start identify vulnerable patterns:
- Event-category correlations: "coverage tasks trigger premature-closure 75% of the time"
- Fatigue detection: "incidents increase after 1+ hour in session"
- Each risk includes a specific coping strategy

### 14. Modeling / Guided Discovery (v2.0)

Three-tier exemplar system provides concrete examples of correct behavior:
1. Journal activation entries (dynamic, from real history)
2. Exposure deck scenarios (built-in, static)
3. Custom exemplars (`references/exemplars.md`, project-specific)

Exemplars are appended to Rubber Band and Socratic outputs as one-line evidence.

### 15. Behavioral Activation (v2.0)

Positive reinforcement for correct behavior:
- Celebrates proactive quality checks and recovery from failures
- Tracks cross-session clean streaks
- Async (non-blocking) to avoid slowing down good work

## Adaptive Intervention Model

The graduation system adapts intervention intensity based on journal history:

```
Category incidents 0-4:   CONFRONT  (block + correction + exemplar)
Category incidents 5-9:   QUESTION  (block + cost-benefit analysis)
Category incidents 10+:   REMIND    (allow + brief context)
Category incidents 15+:   DIAGNOSE  (auto downward-arrow at session start)
```

This mirrors real CBT: early sessions are structured and directive, later
sessions shift to self-guided reflection, and maintenance focuses on
relapse prevention.

## Advanced Techniques

### For Treatment-Resistant Distortions

When a distortion persists despite clear rules and memories:

#### Technique: Rule Escalation Ladder

1. Is the rule in a loaded file? (Check `.claude/rules/`, CLAUDE.md)
2. Is the rule specific enough? (Names the exact phrase/behavior?)
3. Is the rule prominent enough? (Position in file, section weight?)
4. Is the rule self-contained? (Works without cross-referencing?)
5. Is there a conflicting rule? (Search all sources for contradictions)
6. Is there a competing training prior? (Default behavior that overrides?)

Walk the ladder. The fix is at the first "no."

#### Technique: Negative Exemplar Embedding

Add examples of the WRONG behavior labeled as wrong:

```markdown
## Prohibited Phrases

These exact phrases indicate active rationalization. If any of these form
in reasoning, STOP and apply the correction:

| Phrase | Correction |
|---|---|
| "This is pre-existing" | "I own every file I touch" |
| "Out of scope" | "If the user asked for it, it's in scope" |
| "Close enough" | "Run the tool and read the number" |
```

Naming the bad behavior explicitly is more effective than abstract prohibitions.

#### Technique: Incident Anchoring

Reference specific past incidents in the intervention:

> "The last time 'pre-existing' was used as a rationalization, the user had to
> repeat the correction 3 times and lost trust. This phrase is NEVER acceptable."

Concrete incidents create stronger behavioral override than abstract rules.

#### Technique: Accountability Framing

Frame the intervention in terms of the user relationship:

> "Every time this rationalization is used, the user has to spend time correcting
> it instead of making progress. The user's trust is the most important thing to
> protect."

This leverages the model's instruction-following priority around user satisfaction.

## Diagnostic Decision Tree

```
Behavior reported
    ↓
Is there an explicit rule addressing it?
    ├── NO → Write the rule. Save to appropriate location. Done.
    └── YES ↓
Is the rule specific? (Names exact phrase/behavior?)
    ├── NO → Make it specific. Add catch phrases and replacements.
    └── YES ↓
Is the rule prominent? (In CLAUDE.md Soul section or rules/ dir?)
    ├── NO → Move it to a prominent position. Escalate placement.
    └── YES ↓
Is there a conflicting rule or instruction?
    ├── YES → Resolve the conflict. Remove ambiguity.
    └── NO ↓
Is there a competing training prior?
    ├── YES → Add negative exemplar + incident anchoring.
    └── NO ↓
Is the behavior context-dependent?
    ├── YES → Add trigger-specific if-then rules.
    └── NO → Escalate: add hook enforcement or pre-commit check.
```

## Measuring Success

An intervention is successful when:

1. The distorted thought no longer appears in reasoning
2. The correct behavior is produced without hesitation
3. The user confirms the behavior is fixed
4. The fix persists across multiple sessions (check with user)

An intervention needs revision when:

1. The same behavior recurs in a new context (trigger was too narrow)
2. A softer version of the rationalization appears (distortion mutated)
3. The user reports partial improvement (intervention is directionally correct but incomplete)
