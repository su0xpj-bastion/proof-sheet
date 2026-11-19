# Test plan: proof-sheet 1.0

Follows [TEST_STRATEGY.md](TEST_STRATEGY.md). This covers the 1.0 release of the proof-sheet app (iPhone, iPad and Mac),
its sync and review service, and the web review page.

## Scope

**In scope**: the 45 workflows in [WORKFLOWS.md](../WORKFLOWS.md), grouped as:

| Area | Workflows | P0 | Main risk |
|---|---|---|---|
| Import | W01–W06 | W01, W03, W05 | wrong orientation, lost metadata, duplicates, Live Photo pairs split |
| Photo editing | W07–W12 | W07, W11 | edits lost, undo/revert wrong, paste overwrites framing |
| Video editing | W13–W17 | W13 | frame-accurate trim, speed, sound on picture |
| Colour and metadata | W18–W20 | W20 | wide colour and HDR lost; GPS leaked |
| Export | W21–W23 | W21, W23 | wrong format or size; partial files after cancel or a full disk |
| Cloud | W24–W30 | W24–W28 | upload corruption, offline edits lost, conflicts overwritten, deletes not synced |
| Web review | W31–W35 | W34 | revoked links still working, wrong download, video won't play |
| Platform | W36–W45 | W37, W38, W44, W45 | autosave, access revoked, upgrade loses library |

**Out of scope for 1.0**:
- real-device camera capture
- the system Photos picker UI (the app's handling of each permission state *is* in scope)
- Handoff between two physical devices
- iOS paste (it asks the user for permission each time)
- accuracy on real-world footage (needs a licensed set)

## Approach by area

| Area | How it is tested | Why this way |
|---|---|---|
| Geometry (crop, rotate, straighten, orientation) | coordinate images; read source position from 4 output corners | exact, no golden images to maintain |
| Colour (P3, HDR, filters, exposure) | colour chart and HDR ramp, measured in linear light | catches "a bit darker" that eyes miss |
| Video (trim, speed, filter, titles) | barcoded frames + clicked audio, decoded back | frame and sample exact |
| Metadata and privacy | read EXIF/GPS back from every export preset | privacy is P0 |
| Sync | Swift client against a live Python server with switchable faults | conflicts, offline, quota, expiry, retries |
| UI | XCUITest on iPhone, iPad and Mac with launch arguments for each state | permission states and full disk without system prompts |
| Accessibility | `performAccessibilityAudit`, Dynamic Type, VoiceOver labels | a release requirement, not a later pass |
| Web | Selenium on Safari and Chrome | the review page is used by clients on any browser |
| Cross-device | pytest drives two Swift "devices" and a browser | the joins between features |

## Environments

| Lane | Where | When |
|---|---|---|
| Unit, workflow checks, API, Selenium | macOS CI runner | every push |
| XCUITest | iPhone and iPad simulators (latest iOS), macOS | every push |
| Command Line Tools only | a Mac without Xcode (`scripts/build-local.sh`) | every push: keeps the core portable |
| Real devices | a physical iPhone and Mac, by hand | before release: camera, Neural Engine, thermal |

## Entry and exit criteria

**Entry**:
- the build is green on all three platforms
- the fault matrix runs
- the server contract tests pass

**Exit** (ship), all of these:
- all P0 workflows pass on iPhone, iPad and Mac
- no open P0 or P1 bug
- the fault matrix is exact (13 of 13)
- workflow coverage is 45 of 45
- every known failure is listed in the release report with an owner

## Schedule in a release cycle

| When | What runs | Who looks |
|---|---|---|
| Every pull request | everything above except the real-device lane | the author, and QA on failures |
| Nightly | everything, plus performance baselines | QA: a morning summary to the team |
| Release candidate | everything, plus the real-device pass and exploratory sessions | QA, then the release manager |
| After release | crash and feedback triage against the workflow list | QA and the feature owners |

## Exploratory sessions (release candidate)

Time-boxed, 45 minutes each, with notes kept:
1. Interrupt everything: lock the phone mid-export, kill the app mid-sync, toggle airplane mode while an upload is running.
2. Long and odd media: a 2-hour clip, a 1×5000 panorama, a file with no metadata, a renamed HEIC.
3. Two devices, one photo, edited at the same time, both offline, then both reconnect.
4. VoiceOver only: the full import → edit → share path without looking at the screen.

## Ownership

| Failure in… | Owner | QA's part |
|---|---|---|
| App logic, rendering, video | app engineers | isolate the layer, reproduce on a fixture, bisect |
| Sync and review service | server team | contract test that reproduces it |
| Apple frameworks or OS | app team + Feedback Assistant | minimal repro project |
| Test code or CI | QA | fix within a day, or quarantine with a ticket |
| Accessibility | app engineers + design | audit output and VoiceOver steps |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Simulators differ from devices | a real-device pass for camera, Neural Engine and thermal before release |
| CI timing noise | budgets derived from the design; timing excluded from the fault matrix |
| UI tests are slower and flakier | logic is tested below the UI; a UI test checks wiring and accessibility, not maths |
| Synthetic media hides real-world variation | a licensed real-footage set is the next step; the same gates apply |

## Reporting

- **Every run**: per-test results in JUnit and `.xcresult`, with a screenshot attached to each UI failure.
- **Nightly**: pass rate by priority, new failures, flaky tests.
- **Release**: [RELEASE_REPORT.md](RELEASE_REPORT.md), one page for engineering and non-engineering readers.
- **Bugs**: in the format in the strategy. The real ones from building this are in [BUGS.md](../BUGS.md).
