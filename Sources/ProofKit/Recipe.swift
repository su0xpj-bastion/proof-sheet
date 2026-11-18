import CoreGraphics
import Foundation

/// A rectangle in 0...1 units of the (rotated) image. Never pixels: pixels depend on which
/// device drew the crop and at what preview scale.
public struct NormalizedRect: Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public static let full = NormalizedRect(x: 0, y: 0, w: 1, h: 1)

    /// A crop drawn in pixels on an image shown at `shownSize` (a proxy, a view, or full-res).
    public static func from(pixelRect r: CGRect, shownSize: CGSize, fullSize: CGSize) -> NormalizedRect {
        let base = FaultInjection.on(.cropPixelsNotNormalized) ? fullSize : shownSize
        return NormalizedRect(x: Double(r.minX / base.width), y: Double(r.minY / base.height),
                              w: Double(r.width / base.width), h: Double(r.height / base.height))
    }

    /// Largest centred rectangle of `aspect` (w/h) inside an image of `size`.
    public static func aspect(_ aspect: Double, in size: CGSize) -> NormalizedRect {
        let imageAspect = Double(size.width / size.height)
        if aspect > imageAspect {
            let h = imageAspect / aspect
            return NormalizedRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        }
        let w = aspect / imageAspect
        return NormalizedRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
    }
}

public enum PhotoFilter: String, Codable, CaseIterable {
    case none, mono, sepia
    /// A 3D LUT that swaps red and blue: trivially checkable, catches any LUT axis-order bug.
    case swapLUT
}

/// Non-destructive photo edit. The original file is never touched; this is the sidecar.
public struct PhotoRecipe: Codable, Equatable {
    public static let currentSchema = 2
    public var schema = PhotoRecipe.currentSchema
    /// Stops (EV). +1 doubles linear light.
    public var exposure = 0.0
    public var contrast = 1.0
    public var saturation = 1.0
    /// -1 cool ... +1 warm.
    public var warmth = 0.0
    public var filter = PhotoFilter.none
    /// Clockwise quarter turns, applied before straighten and crop.
    public var quarterTurns = 0
    /// Degrees; the image is scaled up so no empty corners show.
    public var straighten = 0.0
    public var crop = NormalizedRect.full
    public var removeLocation = false

    public init() {}
    public var isIdentity: Bool { self == PhotoRecipe() }

    /// "Paste Edits" carries colour and filter only: geometry belongs to one image's framing.
    public func pasted(onto target: PhotoRecipe) -> PhotoRecipe {
        var r = target
        r.exposure = exposure; r.contrast = contrast; r.saturation = saturation; r.warmth = warmth; r.filter = filter
        return r
    }
}

public struct ClipSegment: Codable, Equatable {
    public var sourceIn: Int
    /// Exclusive.
    public var sourceOut: Int
    public var speedNum: Int
    public var speedDen: Int

    public init(_ sourceIn: Int, _ sourceOut: Int, speed: (Int, Int) = (1, 1)) {
        self.sourceIn = sourceIn; self.sourceOut = sourceOut; speedNum = speed.0; speedDen = speed.1
    }

    public var isRetimed: Bool { speedNum != speedDen }
    public var outputLength: Int {
        let n = (sourceOut - sourceIn) * speedDen, d = speedNum
        return (2 * n + d) / (2 * d)
    }
}

public struct TitleCard: Codable, Equatable {
    public var text: String
    public var outputIn: Int
    /// Exclusive.
    public var outputOut: Int
    public init(text: String, outputIn: Int, outputOut: Int) { self.text = text; self.outputIn = outputIn; self.outputOut = outputOut }
}

public struct VideoRecipe: Codable, Equatable {
    public var segments: [ClipSegment]
    public var volume = 1.0
    public var muted = false
    public var filter = PhotoFilter.none
    public var title: TitleCard?

    public init(segments: [ClipSegment]) { self.segments = segments }

    public var outputFrames: Int { segments.reduce(0) { $0 + $1.outputLength } }
    public func outputStart(_ i: Int) -> Int { segments[..<i].reduce(0) { $0 + $1.outputLength } }
    public func expectedSourceFrames() -> [Int] {
        segments.flatMap { s in (0..<s.outputLength).map { s.sourceIn + $0 * s.speedNum / s.speedDen } }
    }
}

/// Undo/redo over whole recipe snapshots. A slider drag is one step, however many values it passed.
public final class EditHistory<R: Equatable> {
    public private(set) var current: R
    public let original: R
    private var undoStack: [R] = []
    private var redoStack: [R] = []
    private var gestureStart: R?

    public init(_ current: R, original: R) { self.current = current; self.original = original }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoDepth: Int { undoStack.count }

    public func apply(_ r: R) {
        guard r != current else { return }
        undoStack.append(current); redoStack.removeAll(); current = r
    }

    public func beginGesture() { gestureStart = current }

    public func update(_ r: R) {
        if FaultInjection.on(.undoPerDragTick) { apply(r); return }
        current = r
    }

    public func endGesture() {
        defer { gestureStart = nil }
        guard !FaultInjection.on(.undoPerDragTick), let start = gestureStart, start != current else { return }
        undoStack.append(start); redoStack.removeAll()
    }

    public func undo() {
        guard let r = undoStack.popLast() else { return }
        redoStack.append(current); current = r
    }

    public func redo() {
        guard let r = redoStack.popLast() else { return }
        undoStack.append(current); current = r
    }

    /// Back to the original; itself undoable.
    public func revert() { apply(original) }
}
