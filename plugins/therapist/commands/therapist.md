---
description: Diagnose and fix persistent behavioral issues in Claude sessions using a CBT framework. Invoke the therapist skill to walk through the intervention.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
argument-hint: "[describe the unwanted behavior]"
---

You are invoking the `therapist` skill for this plugin.

Load and follow the instructions in `${CLAUDE_PLUGIN_ROOT}/skills/therapist/SKILL.md` exactly. Pass the user's argument (if any) as the behavior description to diagnose.

The skill walks through the full CBT-adapted intervention: diagnosis, reframing, behavioral experiment, and relapse prevention. Do not summarize or skip steps — run the skill end-to-end.
