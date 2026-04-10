# therapist — CBT Behavioral Intervention

Diagnose and fix persistent behavioral issues in Claude/Codex sessions using a CBT framework. Eleven tools with adaptive graduation, behavioral experiments, and relapse prevention.

## Installation

Install via the Codex plugin browser or add this repo as a plugin source.

## Available Skills

- `$therapist` — Run a full CBT intervention: diagnosis, formulation, and treatment plan.

## Platform Differences

On Codex, two hooks fire at different times than on Claude Code:

- **rubber-band** (distortion detection): Fires at the start of each new turn (`UserPromptSubmit`) instead of before each file write. Reviews the previous turn's output holistically.
- **socratic** (reflective questioning): Fires at turn-end (`Stop`) instead of after each file write. Reflects on the full turn's work.

All other hooks (affirmation, pause, mirror, reframe, activate) fire identically on both platforms.
