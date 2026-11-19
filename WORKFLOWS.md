# Workflows

Every workflow a photo and video editor ships, with a stable ID and a priority:
- **P0** — loses or corrupts work, leaks private data, or breaks a core path. Blocks release.
- **P1** — a core feature is wrong or degraded. Blocks release unless waived with an owner.
- **P2** — polish, layout, speed beyond budget. Tracked; does not block alone.

Priorities come from [docs/TEST_STRATEGY.md](docs/TEST_STRATEGY.md) (work loss > privacy > silently wrong output > interaction > polish). `tools/workflow_coverage.py`
fails the build if any ID below has no test, and prints which layers cover each one.

| ID | Workflow | Area | Priority |
|---|---|---|---|
| W01 | Photo import with full library access | Import | P0 |
| W02 | Limited library access, "Select More Photos" | Import | P1 |
| W03 | Video import | Import | P0 |
| W04 | Files app, drag and drop, paste (unsupported types rejected) | Import | P1 |
| W05 | Formats: JPEG, HEIC, PNG, TIFF, DNG RAW; EXIF orientation | Import | P0 |
| W06 | Live Photo pairing by content identifier | Import | P1 |
| W07 | Adjustments: exposure, contrast, saturation, warmth | Photo edit | P0 |
| W08 | Crop, rotate, straighten, aspect presets | Photo edit | P1 |
| W09 | Filters and LUTs | Photo edit | P1 |
| W10 | Undo / redo; press-and-hold compare to original | Photo edit | P1 |
| W11 | Revert to original (undoable) | Photo edit | P0 |
| W12 | Copy / paste edits onto many assets | Photo edit | P1 |
| W13 | Frame-accurate trim | Video edit | P0 |
| W14 | Split, reorder, speed change | Video edit | P1 |
| W15 | Audio volume, mute, A/V sync | Video edit | P1 |
| W16 | Filter applied to every frame | Video edit | P1 |
| W17 | Title card with in/out frames | Video edit | P2 |
| W18 | Display P3 kept; sRGB conversion on export | Colour + metadata | P1 |
| W19 | HDR kept, or tone mapped for SDR | Colour + metadata | P1 |
| W20 | EXIF kept; "Remove Location" strips GPS | Colour + metadata | P0 |
| W21 | Export presets: JPEG, HEIC, PNG / H.264, HEVC, ProRes | Export | P0 |
| W22 | Share sheet / Save to Photos | Export | P1 |
| W23 | Export progress, cancel, full disk | Export | P0 |
| W24 | Chunked, resumable upload with checksum | Cloud | P0 |
| W25 | Edit on iPhone, open on Mac: same result | Cloud | P0 |
| W26 | Offline edits queue and sync on reconnect | Cloud | P0 |
| W27 | Concurrent edits: conflict kept as a copy | Cloud | P0 |
| W28 | Delete, Recently Deleted, restore across devices | Cloud | P0 |
| W29 | Storage full, expired sign-in, transient 503 | Cloud | P1 |
| W30 | Version history and restore | Cloud | P1 |
| W31 | Share link opens a web review page | Web review | P1 |
| W32 | Comments pinned to a photo region or video timecode | Web review | P1 |
| W33 | Approve / request changes, status back in the app | Web review | P1 |
| W34 | Link expiry, revoke, password | Web review | P0 |
| W35 | Download original vs edited | Web review | P1 |
| W36 | Deep links and Handoff | Platform | P1 |
| W37 | Autosave and relaunch mid-edit | Platform | P0 |
| W38 | Photos access revoked mid-session | Platform | P0 |
| W39 | VoiceOver labels, Dynamic Type, accessibility audit | Platform | P1 |
| W40 | Localization: right-to-left, long strings | Platform | P2 |
| W41 | Dark and light appearance | Platform | P2 |
| W42 | iPad split view / multiple Mac windows | Platform | P2 |
| W43 | Performance budgets: render, export, scrub, launch | Platform | P2 |
| W44 | Edit format migration v1 to v2 | Platform | P0 |
| W45 | App upgrade keeps library and unsynced edits | Platform | P0 |
