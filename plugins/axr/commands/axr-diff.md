---
description: Compare two AXR scoring runs and surface what changed.
argument-hint: "[<from-file>] [<to-file>]"
allowed-tools: Bash, Read
---

You are the `/axr-diff` command. Compare two AXR scoring runs.

## Steps

1. **Determine files to compare.**
   - If no arguments: find the most recent file in `.axr/history/` (by filename sort, they're ISO timestamps) as FROM, use `.axr/latest.json` as TO.
   - If one argument: use it as FROM, `.axr/latest.json` as TO.
   - If two arguments: use first as FROM, second as TO.
   - If `.axr/latest.json` doesn't exist OR `.axr/history/` is empty (for default mode): abort with "No scoring history found. Run /axr at least twice to generate history."

2. **Run diff.** `"${CLAUDE_PLUGIN_ROOT}/scripts/diff-scores.sh" "$FROM" "$TO"`

3. **Print summary:**
   ```
   AXR Diff: <from_date> → <to_date>
   Score: <from_score> → <to_score> (<sign><delta>)
   Band: <from_band> → <to_band>  (or "unchanged" if same)

   Dimensions changed:
     <dim_id>: <from_weighted> → <to_weighted> (<sign><delta>)
     ...

   Criteria improved (<count>):
     <id>: <from_score> → <to_score>
     ...

   Criteria regressed (<count>):
     <id>: <from_score> → <to_score>
     ...

   Blockers resolved (<count>):
     - <label>
   Blockers introduced (<count>):
     - <label>
   ```
