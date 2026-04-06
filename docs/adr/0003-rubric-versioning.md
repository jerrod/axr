# 3. Rubric Versioning Policy

**Status:** Accepted

## Context

The rubric defines criteria, weights, and score bands. Changes to any of these affect scoring behavior. Downstream consumers (CI gates, dashboards, trend data) depend on stable rubric semantics.

## Decision

Never edit a rubric JSON file in place. Instead, create a new version file (`rubric.v3.json`) and update `_AXR_RUBRIC_PATH` in `common.sh`. Preserve prior versions for history comparison via `/axr-diff`.

## Consequences

- Trend data remains comparable within a rubric version
- Breaking changes (reweighting, criteria renaming) require a version bump
- Old rubric files accumulate but are small (~15KB each)
- `aggregate.sh` and `patch-dimension.sh` read weights dynamically from the rubric, so they adapt to new versions without code changes
