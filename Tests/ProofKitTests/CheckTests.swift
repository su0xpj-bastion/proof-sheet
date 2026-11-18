import ProofChecks
import XCTest

/// One XCTest per workflow check, so Xcode, Jenkins and Xcode Cloud report each by name.
/// Generated from `ps list`; WorkflowCoverageTests fails if this list drifts from Checks.all.
final class CheckTests: XCTestCase {
    func test_import_formats() throws { try Checks.run("import.formats") }
    func test_import_orientation() throws { try Checks.run("import.orientation") }
    func test_import_library() throws { try Checks.run("import.library") }
    func test_import_live_photo() throws { try Checks.run("import.live-photo") }
    func test_access_limited() throws { try Checks.run("access.limited") }
    func test_access_revoked() throws { try Checks.run("access.revoked") }
    func test_edit_exposure() throws { try Checks.run("edit.exposure") }
    func test_edit_color_controls() throws { try Checks.run("edit.color-controls") }
    func test_edit_crop_from_proxy() throws { try Checks.run("edit.crop-from-proxy") }
    func test_edit_rotate_straighten_aspect() throws { try Checks.run("edit.rotate-straighten-aspect") }
    func test_edit_filters_lut() throws { try Checks.run("edit.filters-lut") }
    func test_edit_undo_redo() throws { try Checks.run("edit.undo-redo") }
    func test_edit_revert() throws { try Checks.run("edit.revert") }
    func test_edit_paste_batch() throws { try Checks.run("edit.paste-batch") }
    func test_video_trim() throws { try Checks.run("video.trim") }
    func test_video_split_reorder_speed() throws { try Checks.run("video.split-reorder-speed") }
    func test_video_audio() throws { try Checks.run("video.audio") }
    func test_video_filter_every_frame() throws { try Checks.run("video.filter-every-frame") }
    func test_video_title() throws { try Checks.run("video.title") }
    func test_color_p3_gamut() throws { try Checks.run("color.p3-gamut") }
    func test_color_hdr() throws { try Checks.run("color.hdr") }
    func test_metadata_exif_gps() throws { try Checks.run("metadata.exif-gps") }
    func test_export_photo_presets() throws { try Checks.run("export.photo-presets") }
    func test_export_video_presets() throws { try Checks.run("export.video-presets") }
    func test_export_cancel_and_disk() throws { try Checks.run("export.cancel-and-disk") }
    func test_sync_resumable_upload() throws { try Checks.run("sync.resumable-upload") }
    func test_sync_cross_device() throws { try Checks.run("sync.cross-device") }
    func test_sync_offline_queue() throws { try Checks.run("sync.offline-queue") }
    func test_sync_conflict_keep_both() throws { try Checks.run("sync.conflict-keep-both") }
    func test_sync_delete_restore() throws { try Checks.run("sync.delete-restore") }
    func test_sync_quota_auth_retry() throws { try Checks.run("sync.quota-auth-retry") }
    func test_sync_versions() throws { try Checks.run("sync.versions") }
    func test_share_comments_status() throws { try Checks.run("share.comments-status") }
    func test_share_revoke_expiry_password() throws { try Checks.run("share.revoke-expiry-password") }
    func test_share_downloads() throws { try Checks.run("share.downloads") }
    func test_continuity_handoff_deeplink() throws { try Checks.run("continuity.handoff-deeplink") }
    func test_library_autosave() throws { try Checks.run("library.autosave") }
    func test_library_migration() throws { try Checks.run("library.migration") }
    func test_perf_budgets() throws { try Checks.run("perf.budgets") }
}
