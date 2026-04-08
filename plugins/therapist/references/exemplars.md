# Custom Exemplars

Project-specific examples of correct behavior, keyed by distortion category.
These are used by the Modeling / Guided Discovery technique as the third-tier
fallback when no journal history or exposure deck match exists.

Add your own examples below. The `journal.sh exemplar <category>` command
searches for list items (`- `) under the matching category heading.

---

## Ownership Avoidance

- Inherited a file with 12 lint warnings. Fixed all 12 before adding new code. Zero warnings at commit.
- Found a deprecated API call in a utility function. Updated it while implementing the new feature.

## Premature Closure

- Coverage was 93.8%. Wrote 3 more test cases targeting uncovered branches. Final: 97.2%.
- Saw "close enough" forming as a thought. Ran the tool instead. Discovered 2 edge cases.

## Scope Deflection

- User asked for validation on all endpoints. Completed all 12, including 4 in unfamiliar code.
- Found a related bug while implementing a feature. Fixed it in the same PR instead of deferring.

## Learned Helplessness

- Flaky test seemed impossible. Tried 3 approaches: isolated state, added retry logic, found race condition. Fixed.
- "Not fixable" feeling arose after 20 minutes. Stepped back, re-read the error, found the root cause in 5 more minutes.

## Effort Avoidance

- Refactoring was needed to fix the bug properly. Did the refactoring instead of patching around it.
- Test setup was tedious (real database fixture). Set it up properly instead of mocking the internal module.
