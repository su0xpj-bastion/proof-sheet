# Bugs found while building proof-sheet

Real bugs, written up the way they would be filed. Severity: S1 (data loss or privacy), S2 (wrong
output), S3 (broken interaction), S4 (cosmetic). Priority follows [docs/TEST_STRATEGY.md](docs/TEST_STRATEGY.md).

---

### PS-1 · Ordinary photos export about 25% darker than the original
**S2 / P0** · found by `import.orientation` and `color.p3-gamut` on the first full run

- **Steps.** `scripts/build-local.sh check import.orientation`. Export the coordinate JPEG with exposure +0.01 to JPEG sRGB, then read the four corners back.
- **Expected.** Each corner names its source position: top-left (0.00, 1.00).
- **Actual.** Top-left read (0.00, 0.758). Every value was scaled by about 0.76. A P3 green patch came back (0.34, 0.75, 0.22) instead of (0, 1, 0).
- **Isolation.** Geometry was right and only values were scaled, so it was a colour stage, not crop or rotate. Rendering without export was correct, so it was an export stage. Disabling tone mapping made it disappear: the HDR tone curve was running on SDR images.
- **Root cause.** Tone mapping was applied to every export.
- **Fix.** Tone-map only when the *source* has highlights above diffuse white.
- **Guard.** `import.orientation`, `color.p3-gamut`, `export.photo-presets`, and `color.hdr` for the HDR side.

### PS-2 · The HDR check calls ordinary JPEGs HDR
**S2 / P0** · found while fixing PS-1

- **Steps.** Measure the peak of `camera.jpg` and `chart-p3.png` in linear light.
- **Expected.** Below 1.0: these are SDR files.
- **Actual.** 1.007 (JPEG decode overshoot) and 1.013 (P3 green converted to Rec. 2020). Both crossed a 1.001 threshold.
- **Isolation.** A threshold sweep, plus the peak printed per file, showed decode and gamut overshoot, not real highlights.
- **Fix.** The threshold is now 1.05, measured in linear Rec. 2020.
- **Regression drill.** `scripts/bisect-drill.sh` re-introduces this exact change among 8 commits. `git bisect run` names the commit after 3 test runs (about 45 s).

### PS-3 · Review videos don't seek in Chrome and don't play in Safari
**S3 / P1** · found by Selenium `test_comment_at_video_timecode`

- **Steps.** Open a share link for a video and set `currentTime = 1.5015` (frame 45 at 29.97).
- **Expected.** The playhead moves and a comment can be pinned at 00:01:15.
- **Actual.** `currentTime` stays at 0, and the wait times out.
- **Isolation.** The same file seeks when played from disk. Requests showed the server ignoring `Range` and always answering `200` with the whole file. Safari requires `206 Partial Content` for video.
- **Fix.** The server honours `Range` (206, `Content-Range`, 416 when out of range).
- **Guard.** `test_media_supports_byte_ranges` and the Selenium timecode test.

### PS-4 · A request with a body breaks the next request on the same connection
**S2 / P0** · found by the first sync checks: every one failed with HTTP 501

- **Actual.** The server returned `501 Unsupported method ('{"device":"iphone"}POST')`.
- **Isolation.** The method string started with the previous request's JSON body. The server only read a body on some routes, so on keep-alive connections the unread bytes were parsed as the next request line.
- **Fix.** Read each request body exactly once, before routing.
- **Guard.** All sync checks run on persistent connections.

### PS-5 · A slider moved by VoiceOver or the keyboard adds no undo step
**S3 / P1** · found while designing `edit.undo-redo` against the UI

- **Isolation.** SwiftUI calls `onEditingChanged` for drags only. Accessibility and keyboard increments change the value with no gesture, so the history treated them as part of a drag that never ended.
- **Fix.** An update with no drag in progress is its own undo step.
- **Guard.** `test_W10_undoRedoCompare` drives the slider with keyboard steps on macOS.

### PS-6 · Editor buttons below the fold don't exist for VoiceOver or UI tests
**S3 / P1** · found by XCUITest on iPhone (`undoButton never appeared`, and 6 more)

- **Isolation.** The buttons existed on iPad (taller screen) and not on iPhone. A `LazyVGrid` doesn't create cells that are off screen, so they aren't in the accessibility tree.
- **Fix.** Use a plain stack.
- **Guard.** W07–W12 on the iPhone destination.

### PS-7 · Accessibility audit: library rows read as file names; a toolbar button ignores Dynamic Type
**S3 / P1** · found by `performAccessibilityAudit` (`Label not human-readable: 'Coordinates.jpg'`, `Dynamic Type font sizes are partially unsupported: 'Revoke'`)

- **Fix.** Rows read "Coordinates, photo, edited", and the toolbar uses an icon with a label.
- **Guard.** `test_W39_accessibilityAudit` on iPhone, iPad and Mac.

### PS-8 · The Mac window is taller than a 768-pixel screen
**S3 / P2** · found by XCUITest on a CI Mac (`Not hittable` on editor controls)

- **Isolation.** The window was 912 pixels tall on a 1024×768 display. Controls below 768 could not be clicked or scrolled into view.
- **Fix.** Minimum height is now 600, and tests scroll elements into view.

---

## Test-infrastructure bugs (not product bugs, but they cost time)

- **Stale chromedriver.** Version 90 on PATH against Chrome 157 failed every Selenium test. Selenium Manager now resolves a matching driver.
- **`tests/` and `Tests/` are the same folder** on macOS's case-insensitive disk, so pytest could not find its tests. The Python suite moved to `tests_py/`.
- **GitHub's macOS concurrency limit.** The 6th parallel macOS job was never scheduled. UI and Selenium jobs now wait for the first job.
- **macOS XCUITest on hosted runners (quarantined).** On GitHub's macOS VMs the app under test loses foreground partway through the suite (`Application ... is not foreground and does not allow background interaction`). After that, elements "never appear" in tests that otherwise pass. The job still runs on every push and uploads its results, but it no longer fails the build (`continue-on-error`). It comes out of quarantine once it runs on a dedicated Mac agent with a logged-in session; the Jenkinsfile already supports that. iPhone and iPad XCUITest still block the build.
- **Test hooks flagged by the accessibility audit.** The asset-ID labels exist only in UI-test launches, but the audit at Accessibility XL counted them as Dynamic Type problems. The audit now ignores them, the same way it ignores the appearance and layout probes.
- **`reveal` scrolled the wrong view on iPhone.** `scrollViews.firstMatch` was not the editor's scroll view, so with doubled-length strings Export stayed off screen (y = 1091 in a 912-point window). On iPhone the test now drags the window itself.
