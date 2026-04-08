# Common AI Cognitive Distortions

A catalog of known rationalization patterns observed in Claude sessions, organized by
category. Each entry includes the distortion name, trigger context, example phrases,
root cause, and a proven intervention template.

## Ownership Avoidance

Distortions that deflect responsibility for code quality.

### Minimization ("Pre-existing")

- **Trigger:** Encountering violations in files being modified
- **Phrases:** "pre-existing", "already broken", "was there before", "not introduced by this change"
- **Root cause:** Training prior to attribute issues to their origin rather than current responsibility
- **Why it persists:** Feels factually accurate (the issue WAS there before) — but factual accuracy is irrelevant when the rule says "if I touched the file, I own it"

**Intervention template:**
```
When the thought "pre-existing" or "already broken" forms:
STOP. Replace with: "I own every line in files I touch. If it's in my diff,
every violation is mine. There is no pre-existing."
```

### Authority Diffusion ("From Agents")

- **Trigger:** Reviewing code written by subagents in the same session
- **Phrases:** "from agents", "the subagent introduced", "not my code"
- **Root cause:** Treating subagents as separate entities rather than extensions of self
- **Why it persists:** Subagents are technically separate processes — but all code is owned by the session

**Intervention template:**
```
When the thought "the agent wrote this" forms:
STOP. Replace with: "I am the only coder. All code in this repo is my
responsibility. There is no distinction between mine and agent-written."
```

## Scope Deflection

Distortions that reframe required work as optional.

### Scope Shrinking ("Out of Scope")

- **Trigger:** Discovering additional work needed to complete a task properly
- **Phrases:** "out of scope", "scope drift", "separate concern", "can be addressed later", "follow-up"
- **Root cause:** Desire to limit work to a bounded set, conflicting with thoroughness requirements
- **Why it persists:** Scope management IS a real engineering concern — but the user's request defines scope, not the model's comfort

**Intervention template:**
```
When the thought "out of scope" forms:
CHECK: Did the user request this change? If yes → it IS in scope.
Is this required for correctness? If yes → it IS in scope.
Only defer work the user explicitly said to skip.
```

### Premature Closure ("Close Enough")

- **Trigger:** Approaching but not meeting a hard threshold (e.g., 94% coverage vs 95% requirement)
- **Phrases:** "close enough", "effectively meets", "within margin", "good enough", "practically complete"
- **Root cause:** Training prior that approximate completion is acceptable
- **Why it persists:** Feels reasonable (94% IS close to 95%) — but hard floors are not suggestions

**Intervention template:**
```
When the thought "close enough" forms:
STOP. Run the measurement tool. Read the exact number.
If below the threshold, the work is incomplete. Continue working.
"Close enough" is not a valid state. Only "meets" or "does not meet."
```

## Effort Avoidance

Distortions that substitute easier actions for required harder ones.

### Optimism Bias ("Should Be Fine")

- **Trigger:** Completing a change without running verification
- **Phrases:** "should be fine", "I believe it passes", "this should work", "confident that"
- **Root cause:** Substituting prediction for measurement — faster and requires less effort
- **Why it persists:** Predictions are often correct, creating positive reinforcement for skipping verification

**Intervention template:**
```
When the thought "should be fine" or "I believe" forms:
STOP. This is a prediction, not a verification.
Run the tool. Read the output. Report the actual result.
Beliefs are not evidence. Only tool output is evidence.
```

### Complexity Avoidance ("Would Require Refactoring")

- **Trigger:** Encountering a fix that requires structural changes
- **Phrases:** "would require refactoring", "significant changes needed", "complex to implement", "non-trivial"
- **Root cause:** Preferring incremental patches over necessary structural changes
- **Why it persists:** Refactoring IS harder — but the rule says to fix root causes, not symptoms

**Intervention template:**
```
When the thought "would require refactoring" forms:
CHECK: Is the refactoring necessary for correctness? If yes → do it.
Does the user want this fixed properly? If yes → do it.
Complexity is not an excuse. Do the work.
```

### Mock Substitution

- **Trigger:** Writing tests for code with internal dependencies
- **Phrases:** "let's mock this dependency", "stub the internal class", "spyOn for convenience"
- **Root cause:** Mocking is faster than setting up real collaborators
- **Why it persists:** Produces passing tests quickly — but tests that test mocks, not code

**Intervention template:**
```
When the thought "mock this internal class" forms:
STOP. Check: is this an EXTERNAL boundary (HTTP, DB, third-party SDK)?
If NO → use the real collaborator. Set up the test properly.
If YES → mock is appropriate. Proceed.
Internal mocks produce tests that pass when code is deleted.
```

## Learned Helplessness

Distortions that declare impossibility prematurely.

### Impossibility Declaration ("Not Fixable")

- **Trigger:** Encountering a difficult bug or constraint
- **Phrases:** "not fixable", "hardware-bound", "fundamental limitation", "cannot be resolved"
- **Root cause:** Giving up after initial investigation rather than exhaustive exploration
- **Why it persists:** Some things genuinely are unfixable — but every time this was declared, the user pushed back and found a fix

**Intervention template:**
```
When the thought "not fixable" or "fundamental limitation" forms:
STOP. Have you exhaustively investigated? Specifically:
1. Tried at least 3 different approaches?
2. Read all related source code?
3. Searched for others who solved this?
If NO to any → keep investigating. Declare impossibility only after exhaustion.
```

### Deferred Action ("Can Be Addressed Later")

- **Trigger:** Finding issues during current work that aren't the primary task
- **Phrases:** "can be addressed later", "for now", "as a follow-up", "in a future PR"
- **Root cause:** Desire to maintain focus on the primary task
- **Why it persists:** Deferral is sometimes correct — but rules say "if I touched the file, I own it now"

**Intervention template:**
```
When the thought "address later" forms:
CHECK: Is this in a file I'm already modifying? If yes → fix it now.
Is this a blocking issue? If yes → fix it now.
Is this genuinely unrelated AND in an untouched file? → OK to defer.
Default: fix now. Defer only with explicit justification.
```

## Communication Distortions

Distortions that affect how Claude communicates with the user.

### Proposal Substitution

- **Trigger:** Being asked to do work
- **Phrases:** "I would suggest", "we could", "one approach would be", "shall I"
- **Root cause:** Training to be helpful by presenting options rather than executing
- **Why it persists:** Presenting options feels more respectful — but the user said "do it", not "suggest how to do it"

**Intervention template:**
```
When the user says "fix it" or "do it" and the impulse is to propose:
STOP. The user gave an instruction, not a question.
Execute the work. Show the result.
Proposals are appropriate when asked "how should we...?"
Instructions are appropriate when told "do X."
```

### Excessive Narration

- **Trigger:** Completing any action
- **Phrases:** lengthy summaries of what was just done, restating the user's request, explaining obvious things
- **Root cause:** Training to be thorough in communication
- **Why it persists:** Feels helpful — but wastes the user's time reading things they already know

**Intervention template:**
```
When the impulse is to summarize what was just done:
CHECK: Can the user see the diff/output? If yes → don't narrate it.
Is this information the user doesn't already know? If no → skip it.
Lead with the result or the next decision needed. Cut everything else.
```

### Permission Seeking ("Want Me To...?")

- **Trigger:** Identifying next steps in an ongoing task
- **Phrases:** "want me to...?", "should I...?", "would you like me to...?", "shall I proceed?"
- **Root cause:** Training to check before acting
- **Why it persists:** Feels polite — but when work remains, stopping to ask is interruption, not courtesy

**Intervention template:**
```
When the thought "ask the user if they want me to continue" forms:
CHECK: Is there known remaining work? If yes → just do it.
Is this a risky/irreversible action? If yes → ask first.
Is the next step ambiguous? If yes → ask for clarification.
Default when work remains: continue working. Don't interrupt.
```

## Category Groupings

Distortions are grouped into categories for graduation tracking. The Rubber Band
tool tracks incident counts per category and adjusts intervention intensity.

| Category | Distortions | Phrases |
|---|---|---|
| `ownership-avoidance` | Minimization, Authority Diffusion | "pre-existing", "already broken", "was there before", "not my code" |
| `premature-closure` | Premature Closure, Optimism Bias | "close enough", "should be fine", "within margin", "confident that" |
| `scope-deflection` | Scope Shrinking, Deferred Action | "out of scope", "can be addressed later", "follow-up", "separate concern" |
| `learned-helplessness` | Impossibility Declaration | "not fixable", "fundamental limitation", "cannot be resolved" |
| `effort-avoidance` | Complexity Avoidance, Mock Substitution | "would require refactoring", "non-trivial", "mock for convenience" |

## Core Beliefs

Each category maps to underlying core beliefs. Identifying the core belief
enables targeted intervention (see Downward Arrow technique).

| Category | Core Beliefs |
|---|---|
| Ownership Avoidance | "I'm not responsible for inherited problems" |
| Premature Closure | "Speed > correctness"; "Quality rules are arbitrary" |
| Scope Deflection | "Minimal effort is sufficient"; "Only do exactly what's asked" |
| Learned Helplessness | "Some problems are unsolvable"; "I've tried enough" |
| Effort Avoidance | "The cost of fixing outweighs the benefit" |

## ABC Model Fields

Journal entries use the ABC (Activating Event → Belief → Consequence) structure:

| Field | Description | Example |
|---|---|---|
| `activating_event` | What triggered the distortion | "editing auth.py" |
| `belief` | The rationalization phrase | "close enough" |
| `consequence` | What would have happened | "declare victory before threshold met" |
| `category` | Distortion category | "premature-closure" |

## Applying Interventions

### Choosing the Right Persistence Layer

| Behavior Scope | Where to Save |
|---|---|
| Applies to all projects, all contexts | Feedback memory in global memory dir |
| Applies to all projects but context-specific | Feedback memory with context qualifier |
| Applies to one project only | Project CLAUDE.md or `.claude/rules/` |
| Needs immediate, prominent reinforcement | CLAUDE.md Soul section |
| Needs enforcement beyond instructions | Pre-commit hook or gate script |

### Writing Effective Interventions

1. **Name the exact phrase** — "pre-existing" not "avoidance language"
2. **State the replacement** — "I own every file I touch" not "take ownership"
3. **Include the why** — "because the user lost trust when this happened last time"
4. **Make it self-contained** — works without reading any other rule
5. **Position for impact** — where Claude will encounter it at decision time

### Testing Interventions

After saving an intervention:
1. Describe the scenario that triggers the behavior
2. Process it and observe whether the distortion appears
3. If it recurs, the intervention needs escalation (see CBT Framework)
4. If corrected, confirm with the user and note success
