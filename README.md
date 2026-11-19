# proof-sheet

<!-- plain-english:begin -->
[![ci](https://github.com/su0xpj-bastion/proof-sheet/actions/workflows/ci.yml/badge.svg)](https://github.com/su0xpj-bastion/proof-sheet/actions/workflows/ci.yml)

A small photo and video editor for iPhone, iPad and Mac, built to show how I test
a creative app end to end. You can import, edit, export, share, sync to a cloud, and send a
client a review link that they approve in a browser. I listed the **45 things people actually
do** in an app like this, and every one has an automated test. The build fails if any workflow
is left untested.

Most bugs in creative apps hide in the joins between features. Two examples:
an edit made offline on a phone gets silently lost when the Mac syncs, or a "remove location"
option leaves GPS in the file. This repo tests those joins, not just single screens.

- A SwiftUI app and a Swift library (Core Image editing, AVFoundation video, sync with conflict handling).
- A small Python server for sync and the review page.
- Tests at every layer:
  - XCTest for the logic.
  - XCUITest robots tapping through the app on iPhone, iPad and Mac.
  - pytest for the server.
  - Selenium driving the review page in Safari and Chrome.
  - A cross-device journey: edit on iPhone, render on Mac, approve on the web, see "approved" back on the iPhone.
- One set of scripts that Jenkins, GitHub Actions and Xcode Cloud all run. 13 planted bugs, each proven caught.

Along the way, the tests turned up:
- Ordinary photos exporting about 25% too dark.
- Review videos that wouldn't play or scrub in Safari (missing HTTP range support).
- A server request-parsing bug.
- Buttons that VoiceOver users couldn't reach.

Swift, SwiftUI, Core Image, AVFoundation, ImageIO, XCTest, XCUITest
(including the accessibility audit), Python, pytest, Selenium, Jenkins, GitHub Actions and Xcode
Cloud. Status is honest: see the badge. The unit, server and browser jobs run first, and the
UI-robot jobs are the last to stabilise on CI.

---

## Technical detail
<!-- plain-english:end -->

A small photo and video editor for iOS and macOS (SwiftUI), with cloud sync and a web review
page (Python). It is built to be tested: **45 workflows** of a creative app
([WORKFLOWS.md](WORKFLOWS.md)), each covered by at least one test in **XCTest**, **XCUITest**,
**pytest** or **Selenium**. The suites run in **Jenkins**, in **GitHub Actions**, and through the
same shared Xcode schemes that **Xcode Server** bots and **Xcode Cloud** use.

The test images report what they show. In the coordinate image, red = x and green = y, so any
output pixel names the source pixel it came from. Crop, rotate, straighten and EXIF orientation
are checked from four corners, with no golden images. Every video frame carries its number as a
barcode, and the audio has a click every 10 frames. Trim, reorder, speed, title timing and A/V
sync are therefore checked to the frame and to the sample.

```
App/                 SwiftUI app (iOS + macOS), XCUITest suite, XcodeGen spec
Sources/ProofKit     recipes, Core Image renderer, AVFoundation edits, import/export, sync client
Sources/ProofChecks  39 workflow checks (run by XCTest and by the `ps` CLI)
Tests/ProofKitTests  XCTest: one test per check, client fault matrix, XCTest metrics
cloud/               stdlib Python server: chunked upload, ETag versions, share links, review page
tests_py/            pytest: API contract, Selenium review page, iPhone→Mac→web E2E
tools/               fault_matrix.py, workflow_coverage.py
Jenkinsfile          pipeline; every stage calls scripts/ci/*.sh (GitHub Actions runs the same scripts)
ci/xcode-server/     Xcode Server bot setup (legacy) and how Xcode Cloud replaces it
ci_scripts/          Xcode Cloud post-clone hook
```

## What each layer covers

| Layer | Runs | Workflows |
|---|---|---|
| XCTest (`ProofKitTests`) | `swift test`, the macOS scheme, Xcode Server/Cloud | import formats + RAW, Live Photo pairing, colour/LUT/geometry maths, undo model, video frames + audio samples, P3/HDR/EXIF/GPS, export codecs, cancel/full disk, sync client against the live server, migration, perf budgets + `XCTClockMetric`/`XCTMemoryMetric` |
| XCUITest (`ProofSheetUITests`) | iPhone + iPad simulators, macOS | import, limited access, Finder paste, sliders/crop/filters, undo/redo/compare, revert, paste edits, trim/speed/mute, export + share sheet, cancel/full disk, offline queue, deep link, relaunch, access revoked, accessibility audit, Arabic RTL + doubled strings, dark mode, iPad/multi-window, launch time, v1 library upgrade |
| pytest | anywhere with Python 3 | upload checksum/resume, If-Match conflicts, Recently Deleted, quota/expired token/503, versions, link lifecycle, byte ranges |
| Selenium | Safari (macOS), Safari in the iOS Simulator, headless Chrome | review page opens, comments pinned to a photo region and a video timecode, approve/request changes, revoked/expired/password links, downloads |
| E2E (pytest drives Swift `ps` + Selenium) | Jenkins / Actions | iPhone edits on a proxy → Mac renders full size → reviewer approves in a browser → the iPhone sees "approved" |

`python tools/workflow_coverage.py` prints the matrix and fails if any workflow has no test.

## The fault matrix

`PROOF_FAULTS=<name>` switches on a real bug. Each fault must fail **exactly** its pinned tests,
no fewer and no more. This shows the suites detect the bug, not just run.

| Fault | Caught by |
|---|---|
| cropPixelsNotNormalized | edit.crop-from-proxy, sync.cross-device |
| recipeAppliedTwice | edit.exposure |
| gpsNotStripped | metadata.exif-gps |
| p3ClampedToSRGB | color.p3-gamut |
| hdrClipped | color.hdr |
| trimIncludesOutFrame | video.trim, video.split-reorder-speed, export.video-presets |
| undoPerDragTick | edit.undo-redo |
| livePhotoIgnoresID | import.live-photo |
| migrationDropsPending | library.migration |
| noRetryOn503 | sync.quota-auth-retry |
| uploadNotResumable | sync.resumable-upload · test_upload_status_lists_received_chunks |
| conflictSilentOverwrite | sync.conflict-keep-both · test_recipe_write_needs_matching_etag |
| revokedLinkStillServes | share.revoke-expiry-password · test_share_link_lifecycle · Selenium test_revoked_expired_and_password_links |

## Bugs the tests found while building it

1. **SDR photos were tone-mapped.** The HDR tone curve ran on every export, so ordinary photos came out ~25% darker. `import.orientation` and `color.p3-gamut` caught it. The fix applies tone mapping only when the *source* has highlights above diffuse white.
2. **"Is this HDR?" was too strict.** JPEG decoding overshoots 1.0 by about 1%, and P3 green overshoots by about 2% in linear sRGB. Both made SDR images register as HDR. The fix measures the peak in linear Rec. 2020 with a 1.05 threshold.
3. **No HTTP byte ranges on media.** Selenium could not seek the review video. Without `206 Partial Content`, Safari will not play video at all. The server now honours `Range`, and `test_media_supports_byte_ranges` pins it.
4. **Keep-alive request smuggling in the server.** An unread request body was parsed as the next request (`501 Unsupported method ('{"device":…}POST')`). The fix reads each body exactly once.
5. **A stale `chromedriver` on PATH.** Version 90 against Chrome 157 failed every Selenium test. The driver is now resolved through Selenium Manager with `--skip-driver-in-path`.
6. **A slider dragged by VoiceOver or the keyboard never fires `onEditingChanged`.** The undo history now treats an update with no drag in progress as its own undo step.

## Run it

```bash
scripts/build-local.sh check          # 39 checks, plain swiftc (Command Line Tools only)
swift test                            # same checks as XCTest (needs Xcode)
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest            # API + Selenium (Chrome) + E2E
PROOF_BROWSER=safari .venv/bin/python -m pytest   # after: sudo safaridriver --enable
.venv/bin/python tools/fault_matrix.py
.venv/bin/python tools/workflow_coverage.py
scripts/ci/ui.sh ios-iphone           # XCUITest (needs Xcode + brew xcodegen); also ios-ipad, macos
```

## Verification status

- **Local, verified** (macOS 26, Command Line Tools only, Chrome 157):
  - 39/39 Swift checks.
  - 17/17 pytest tests, including Selenium on Chrome and the E2E.
  - Fault matrix: all 13 faults caught by exactly their pinned tests.
  - Workflow coverage: 45/45.
  - The macOS app builds with `swiftc`, launches and seeds its library.
- **CI-only:** XCTest, XCUITest, Safari and iOS-Simulator Safari need Xcode, so they run in `.github/workflows/ci.yml`.
- **Not run:** the Jenkinsfile has not been executed on a Jenkins server. Its stages are the same scripts CI runs. It needs these plugins: Pipeline, Lockable Resources, Timestamper, JUnit.

## Honest limits

- The system Photos picker and the permission prompt are not driven. The app reads PhotoKit's authorization state, and UI tests inject each state (`-access full|limited|denied`). The library, the sheets and the banners are real.
- Handoff between two physical devices cannot be automated. The `NSUserActivity` payload round-trip and the deep link are tested.
- iOS paste is not tested, because the paste permission prompt can't be scripted. macOS paste from Finder is tested.
- Revoking access mid-session uses a test-only button, standing in for Settings → Privacy.
- The DNG fixture is a minimal Linear DNG written byte by byte, because ImageIO cannot write DNG. It exercises the RAW decode path, not a real camera's colour-filter-array (CFA) data.
- Video exported through `AVAssetExportSession` after a speed change is variable frame rate (see barcode-frames). The speed check therefore runs on the preview, conformed to 29.97.
- Xcode Server was removed in Xcode 13. `ci/xcode-server/` documents the bot setup on the shared schemes, and Xcode Cloud replaces it.

<!-- set:begin -->
---

Six small projects, one idea: test media apps with data that carries its own answer, and prove every test catches the bug it was written for.

- [frame-exact](https://github.com/su0xpj-bastion/frame-exact): timecode and edit maths, to the frame
- [barcode-frames](https://github.com/su0xpj-bastion/barcode-frames): real video edits checked frame by frame
- **[proof-sheet](https://github.com/su0xpj-bastion/proof-sheet)**: a photo/video app with all 45 workflows tested
- [enact-probe](https://github.com/su0xpj-bastion/enact-probe): live AI video, measured the way the viewer feels it
- [vision-gate](https://github.com/su0xpj-bastion/vision-gate): report cards for on-device AI photo features
- [timeline-ml](https://github.com/su0xpj-bastion/timeline-ml): beat detection and transcript search
<!-- set:end -->
