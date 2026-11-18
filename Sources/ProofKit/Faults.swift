import Foundation

/// Deliberate bugs, switched on with PROOF_FAULTS=name,name. Each one is a real way a creative
/// app ships broken; the fault matrix pins exactly which workflow checks must catch it.
/// Server-side faults are read by cloud/server.py from the same variable.
public enum Fault: String, CaseIterable {
    // Swift client / renderer
    case cropPixelsNotNormalized   // crop drawn on a proxy is stored as if it were full-res pixels
    case recipeAppliedTwice        // colour adjustments applied on top of an already-adjusted image
    case gpsNotStripped            // "Remove location" ignored on export
    case p3ClampedToSRGB           // wide-gamut pixels clamped to sRGB before a Display P3 export
    case hdrClipped                // SDR export clips highlights instead of tone mapping
    case trimIncludesOutFrame      // trim out-point treated as inclusive
    case undoPerDragTick           // one slider drag recorded as many undo steps
    case livePhotoIgnoresID        // still and motion paired by file name, not content identifier
    case migrationDropsPending     // v1 -> v2 library migration loses the pending-sync queue
    case noRetryOn503              // client gives up on a transient 503
    // Python server (cloud/server.py)
    case uploadNotResumable        // server forgets received chunks, so resume re-sends everything
    case conflictSilentOverwrite   // server ignores If-Match, last writer silently wins
    case revokedLinkStillServes    // revoked share link keeps serving the asset

    public static let serverSide: Set<Fault> = [.uploadNotResumable, .conflictSilentOverwrite, .revokedLinkStillServes]
}

public enum FaultInjection {
    public static var active: Set<Fault> = {
        let raw = ProcessInfo.processInfo.environment["PROOF_FAULTS"] ?? ""
        return Set(raw.split(separator: ",").compactMap { Fault(rawValue: String($0)) })
    }()

    public static func on(_ f: Fault) -> Bool { active.contains(f) }
}
