# Test strategy: creative apps (photo, video, on-device AI)

This is the strategy behind all six repos. Each repo then has its own test plan.
proof-sheet's plan is the full one ([TEST_PLAN.md](TEST_PLAN.md)).

## What "quality" means here

A creative app is trusted with someone's work. The failures that matter most are, in order:

1. **Losing or corrupting work.** An edit disappears on sync, an export drops a frame, the original
   is overwritten.
2. **Leaking something private.** GPS left in a shared photo, footage sent off the device when it
   shouldn't be.
3. **Quietly wrong output.** Colours shift, sound slips off the picture, a cut lands a frame early,
   an AI feature gets worse after a model update. Nothing crashes, so only measurement catches it.
4. **Broken or slow interaction.** Crashes, freezes, lag, controls that VoiceOver can't reach.
5. **Polish.** Layout in long languages, dark mode, wording.

Priorities (P0–P2) in every plan follow this order.

## Principles

**Test data that knows its own answer.** Every fixture is generated, and carries the truth with it:

| Repo | Fixture | The answer it carries |
|---|---|---|
| barcode-frames, enact-probe | barcoded video frames | the frame number |
| barcode-frames, enact-probe, timeline-ml | audio clicks | exact sample times |
| proof-sheet | coordinate images (red = x, green = y) | where each output pixel came from |
| timeline-ml | synthesized drums and speech | every beat and word, at known times |
| vision-gate | seeded scenes | horizon tilt and subject position |

Assertions are exact, need no human eye, and give the same result on every machine.

**Prove the tests work.** Each repo has a *fault matrix*: realistic bugs that can be switched on one at
a time. CI requires that each bug fails exactly the tests meant to catch it, no fewer and no more.
A suite that stays green with a bug switched on has a hole, and the matrix shows it.

**Test the joins, not just the parts.** Most creative-app bugs live between features. For example:
- an edit made offline on a phone, then synced to a Mac
- a crop drawn on a preview, then exported at full size
- a share link that is revoked after it was sent

proof-sheet lists 45 user workflows. A coverage tool fails the build if any workflow has no test.

**Measure what the user experiences.** Latency comes from decoded frames, not server logs. Sync comes
from audio samples, not timestamps in a file. Colour comes from rendered pixels.

**One pipeline, many runners.** The same `scripts/ci/*.sh` run in Jenkins, GitHub Actions and Xcode
Cloud (Xcode Server, for older setups). Builds do not pass on one system and fail on another
because of a script difference.

## Test levels

| Level | Tool | Runs | Covers |
|---|---|---|---|
| Unit and component | XCTest | every push, about 2 min | maths, models, file formats, rendering, the sync client |
| Workflow checks | XCTest + CLI | every push | a whole user workflow on real files, with no UI |
| API contract | pytest | every push | server behaviour: uploads, conflicts, versions, links |
| UI | XCUITest | every push (iPhone, iPad, Mac) | taps, gestures, accessibility audit, languages, appearance |
| Web | Selenium (Safari, Chrome) | every push | review page, comments, approvals, downloads |
| End to end | pytest drives Swift + Selenium | every push | phone edit → Mac render → web approval → phone status |
| ML quality gates | XCTest + baseline compare | every push | accuracy, robustness, drift between builds and between CPU/GPU/Neural Engine |
| Fault matrix | all of the above | every push | the suites still catch what they claim to |
| Performance | XCTMetric + budgets | every push; baselines per device | render, export, decode, launch, inference |

## Entry and exit for a release

**Entry** (testing starts):
- the build compiles on every platform
- unit tests pass
- the fault matrix runs

**Exit** (ship), all of these:
- every P0 workflow passes on every platform, with no open P0 or P1 bug
- the fault matrix is exact: every planted bug is caught, and no extra tests fail
- no ML gate has regressed against the last release's baseline beyond its tolerance
- known failures are listed in the release report with an owner and a reason

## Bugs: how they are reported

Every bug report has six parts:
- **steps** to reproduce, on a fixture anyone can regenerate
- **expected versus actual**, with numbers
- **isolation**: which layer is at fault (app, framework, OS, server, test), and how that was shown
- **regression point**: when it started (`git bisect` with a workflow check as the oracle; see `scripts/bisect-drill.sh`)
- **severity and priority**
- **the test that now guards it**

Each repo's `BUGS.md` holds the real bugs found while building it, in this format.

## Risks this strategy accepts

- **Synthetic media.** Fixtures are generated, so every answer is exact. Real footage, real music and
  real voices need licensed, labelled sets run through the same gates.
- **Simulators.** Most UI runs are on simulators. Camera, Neural Engine, thermal behaviour and
  device motion need a real-device lane.
- **Shared CI machines.** Timing on a CI VM is noisy. Timing gates use budgets derived from the
  design (for example, one or two chunk lengths), and they flag when the machine itself is too slow,
  instead of failing the app.
