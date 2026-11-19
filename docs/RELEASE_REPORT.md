# Release report (template + a real example)

One page, written for engineering, product and the release manager. Lead with the decision.

## Template

**Decision:** GO / NO-GO / GO with exceptions — one sentence why.

| Signal | Result | Target |
|---|---|---|
| P0 workflows passing (iPhone / iPad / Mac) | x / 19 | 19 / 19 |
| P1 workflows passing | x / 21 | 21 / 21, or waived with an owner |
| Fault matrix | x / 13 exact | 13 / 13 |
| Workflow coverage | x / 45 | 45 / 45 |
| ML and performance budgets vs last release | regressions: n | 0 |
| Open bugs by priority | P0 n, P1 n, P2 n | P0 0, P1 0 |

**Risks:** each with an owner and what would change the decision.

**Exceptions:** each known failure, why it is acceptable, who owns the fix, and by when.

**Since last report:** new failures, fixed, flaky.

---

## Example: filled from CI run 44415856492 (2026-11-18)

**Decision: NO-GO.** Every logic, server and browser check passes, but macOS UI automation is not
yet trustworthy, so P0 workflows on the Mac are unverified at the UI level.

| Signal | Result | Target |
|---|---|---|
| Workflow checks, XCTest (39) + client fault matrix | pass | pass |
| Server contract + Selenium (Safari, Chrome) | pass | pass |
| iPhone UI (19 tests) | 18 pass or skip, 1 fail (W40: Export off screen with doubled-length strings) | all pass |
| iPad UI (19 tests) | 18 pass or skip, 1 fail (W39: contrast in the selected sidebar row) | all pass |
| Mac UI (20 tests) | 5 pass, 15 fail: the test harness could not reach the controls | all pass |
| Workflow coverage | 45 / 45 | 45 / 45 |

**Risks:**
- **Mac UI.** Most macOS failures came from the test harness, not the app. The window was taller
  than the CI screen, toolbar items overflowed, and rows collapse into a single accessibility
  element. Owner: QA. Fixes are in the next run; until it is green, Mac P0 workflows rely on the
  logic-level checks only.
- **iPad contrast.** The selected sidebar row's text is drawn by the system with its own colours.
  Logged for design review rather than failed.

**Exceptions:** none accepted for release.

**Since last report:**
- Fixed: buttons hidden from VoiceOver by a lazy grid; row labels that were raw file names;
  a toolbar button that ignored Dynamic Type.
