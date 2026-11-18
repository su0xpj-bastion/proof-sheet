# Workflows

Every workflow a photo and video editor ships, with a stable ID. `tools/workflow_coverage.py`
fails the build if any ID below has no test, and prints which layers cover each one.

| ID | Workflow | Area |
|---|---|---|
| W01 | Photo import with full library access | Import |
| W02 | Limited library access, "Select More Photos" | Import |
| W03 | Video import | Import |
| W04 | Files app, drag and drop, paste (unsupported types rejected) | Import |
| W05 | Formats: JPEG, HEIC, PNG, TIFF, DNG RAW; EXIF orientation | Import |
| W06 | Live Photo pairing by content identifier | Import |
| W07 | Adjustments: exposure, contrast, saturation, warmth | Photo edit |
| W08 | Crop, rotate, straighten, aspect presets | Photo edit |
| W09 | Filters and LUTs | Photo edit |
| W10 | Undo / redo; press-and-hold compare to original | Photo edit |
| W11 | Revert to original (undoable) | Photo edit |
| W12 | Copy / paste edits onto many assets | Photo edit |
| W13 | Frame-accurate trim | Video edit |
| W14 | Split, reorder, speed change | Video edit |
| W15 | Audio volume, mute, A/V sync | Video edit |
| W16 | Filter applied to every frame | Video edit |
| W17 | Title card with in/out frames | Video edit |
| W18 | Display P3 kept; sRGB conversion on export | Colour + metadata |
| W19 | HDR kept, or tone mapped for SDR | Colour + metadata |
| W20 | EXIF kept; "Remove Location" strips GPS | Colour + metadata |
| W21 | Export presets: JPEG, HEIC, PNG / H.264, HEVC, ProRes | Export |
| W22 | Share sheet / Save to Photos | Export |
| W23 | Export progress, cancel, full disk | Export |
| W24 | Chunked, resumable upload with checksum | Cloud |
| W25 | Edit on iPhone, open on Mac: same result | Cloud |
| W26 | Offline edits queue and sync on reconnect | Cloud |
| W27 | Concurrent edits: conflict kept as a copy | Cloud |
| W28 | Delete, Recently Deleted, restore across devices | Cloud |
| W29 | Storage full, expired sign-in, transient 503 | Cloud |
| W30 | Version history and restore | Cloud |
| W31 | Share link opens a web review page | Web review |
| W32 | Comments pinned to a photo region or video timecode | Web review |
| W33 | Approve / request changes, status back in the app | Web review |
| W34 | Link expiry, revoke, password | Web review |
| W35 | Download original vs edited | Web review |
| W36 | Deep links and Handoff | Platform |
| W37 | Autosave and relaunch mid-edit | Platform |
| W38 | Photos access revoked mid-session | Platform |
| W39 | VoiceOver labels, Dynamic Type, accessibility audit | Platform |
| W40 | Localization: right-to-left, long strings | Platform |
| W41 | Dark and light appearance | Platform |
| W42 | iPad split view / multiple Mac windows | Platform |
| W43 | Performance budgets: render, export, scrub, launch | Platform |
| W44 | Edit format migration v1 to v2 | Platform |
| W45 | App upgrade keeps library and unsynced edits | Platform |
