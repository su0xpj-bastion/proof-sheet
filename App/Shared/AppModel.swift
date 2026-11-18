import Combine
import CoreGraphics
import CoreImage
import Foundation
import ProofKit
#if os(iOS)
import Photos
#endif

/// Launch arguments the UI tests use to put the app in a known state. Each maps to a real
/// condition the app handles in the field (no access, offline, full disk, an old library file).
struct LaunchOptions {
    let args = ProcessInfo.processInfo.arguments
    func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    func flag(_ key: String) -> Bool { args.contains(key) }

    var uiTest: Bool { flag("-uitest") }
    var reset: Bool { flag("-uitest-reset") }
    var seedLibrary: Bool { flag("-seed") }
    var seedInbox: Bool { flag("-inbox") }
    var seedV1: Bool { flag("-seedV1") }
    var offline: Bool { flag("-offline") }
    var access: String? { value("-access") }
    var diskFree: Int64? { value("-diskFree").flatMap { Int64($0) } }
    var exportDelay: Double { value("-exportDelay").flatMap { Double($0) } ?? 0 }
}

final class AppModel: ObservableObject {
    @Published var library = LibraryFile()
    @Published var access: LibraryAccess = .full
    @Published var selection: String?
    @Published var clipboard: PhotoRecipe?
    @Published var inbox: [URL] = []
    @Published var lastError: String?

    let options = LaunchOptions()
    let root: URL
    var originals: URL { root.appendingPathComponent("Originals") }
    var libraryFile: URL { root.appendingPathComponent("library.json") }
    var inboxDir: URL { root.appendingPathComponent("Inbox") }

    init() {
        let base: URL
        if options.uiTest {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("ProofSheet-UITest")
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ProofSheet")
        }
        root = base
        if options.reset { try? FileManager.default.removeItem(at: base) }
        try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        if options.seedV1 { writeV1Library() }
        library = (try? LibraryStore.load(libraryFile)) ?? LibraryFile()
        if options.seedLibrary || options.seedInbox { seedFixtures() }
        access = initialAccess()
        refreshInbox()
    }

    // MARK: access

    func initialAccess() -> LibraryAccess {
        switch options.access {
        case "limited": return .limited(Set(library.assets.prefix(1).map { $0.id }))
        case "denied": return .denied
        case "notDetermined": return .notDetermined
        case "full": return .full
        default:
            #if os(iOS)
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: return .full
            case .limited: return .limited(Set(library.assets.map { $0.id }))
            case .denied, .restricted: return .denied
            default: return options.uiTest ? .full : .notDetermined
            }
            #else
            return .full
            #endif
        }
    }

    var visibleAssets: [Asset] { access.visible(library.assets) }

    var hiddenAssets: [Asset] {
        let shown = Set(visibleAssets.map { $0.id })
        return library.assets.filter { !shown.contains($0.id) }
    }

    func allow(_ id: String) {
        if case .limited(var ids) = access { ids.insert(id); access = .limited(ids) }
    }

    /// Settings > Privacy > Photos turned off while the app is open.
    func revokeAccess() { access = .denied }

    // MARK: library

    func asset(_ id: String?) -> Asset? { library.assets.first { $0.id == id } }

    func save() {
        do { try LibraryStore.save(library, to: libraryFile) } catch { lastError = "\(error)" }
    }

    func importFiles(_ urls: [URL]) {
        do {
            let added = try Importer.importFiles(urls, into: originals, existing: library.assets)
            library.assets += added
            if case .limited(var ids) = access { added.forEach { ids.insert($0.id) }; access = .limited(ids) }
            save()
        } catch LibraryError.unsupported(let name) {
            lastError = "Can't import \(name)"
        } catch {
            lastError = "\(error)"
        }
    }

    /// Every recipe change is written immediately: a crash or relaunch never loses an edit.
    func update(_ id: String, photo: PhotoRecipe) {
        guard let i = library.assets.firstIndex(where: { $0.id == id }), library.assets[i].photo != photo else { return }
        library.assets[i].photo = photo
        if options.offline && !library.pending.contains(PendingOp(assetID: id, kind: .recipe)) {
            library.pending.append(PendingOp(assetID: id, kind: .recipe))
        }
        save()
    }

    func update(_ id: String, video: VideoRecipe) {
        guard let i = library.assets.firstIndex(where: { $0.id == id }) else { return }
        library.assets[i].video = video
        save()
    }

    func pasteEditsToAllOtherPhotos(except id: String?) {
        guard let source = clipboard else { return }
        for i in library.assets.indices where library.assets[i].id != id && library.assets[i].kind != .video {
            library.assets[i].photo = source.pasted(onto: library.assets[i].photo ?? PhotoRecipe())
        }
        save()
    }

    func url(of asset: Asset) -> URL { originals.appendingPathComponent(asset.file) }

    // MARK: fixtures for UI tests

    func refreshInbox() {
        inbox = ((try? FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func seedFixtures() {
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let photo = inboxDir.appendingPathComponent("Coordinates.jpg")
        let chart = inboxDir.appendingPathComponent("Chart.png")
        let clip = inboxDir.appendingPathComponent("Clip.mov")
        if !FileManager.default.fileExists(atPath: photo.path) {
            try? PhotoIO.write(PhotoFixture.coordinateImage(), to: photo, format: .jpeg, properties: PhotoFixture.cameraMetadata)
            try? PhotoIO.write(PhotoFixture.colorChart(), to: chart, format: .png)
            try? VideoFixture.write(frames: 120, to: clip)
        }
        if options.seedLibrary && library.assets.isEmpty { importFiles([photo, chart, clip]) }
    }

    /// A library written by version 1 of the app: pixel crops and a sync queue of bare IDs.
    private func writeV1Library() {
        try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let a = originals.appendingPathComponent("old1.jpg"), b = originals.appendingPathComponent("old2.jpg")
        try? PhotoIO.write(PhotoFixture.coordinateImage(width: 400, height: 300), to: a, format: .jpeg)
        try? PhotoIO.write(PhotoFixture.coordinateImage(width: 300, height: 400), to: b, format: .jpeg)
        let v1 = """
        {"version":1,"items":[{"id":"old1","name":"Beach.jpg","file":"old1.jpg","width":400,"height":300,"ev":0.5,"crop":[100,75,200,150]},
        {"id":"old2","name":"Portrait.jpg","file":"old2.jpg","width":300,"height":400}],"queue":["old1"]}
        """
        try? Data(v1.utf8).write(to: libraryFile)
    }
}

extension PhotoRecipe {
    /// One line the UI shows and the UI tests read.
    var summary: String {
        if isIdentity { return "original" }
        var parts: [String] = []
        if exposure != 0 { parts.append(String(format: "exposure %.2f", exposure)) }
        if contrast != 1 { parts.append(String(format: "contrast %.2f", contrast)) }
        if saturation != 1 { parts.append(String(format: "saturation %.2f", saturation)) }
        if warmth != 0 { parts.append(String(format: "warmth %.2f", warmth)) }
        if filter != .none { parts.append("filter \(filter.rawValue)") }
        if quarterTurns % 4 != 0 { parts.append("turns \(quarterTurns % 4)") }
        if crop != .full { parts.append(String(format: "crop %.2fx%.2f", crop.w, crop.h)) }
        if removeLocation { parts.append("no location") }
        return parts.joined(separator: " · ")
    }
}

/// Renders a recipe for display, off the main thread.
enum Preview {
    static func image(_ url: URL, _ r: PhotoRecipe, maxDimension: CGFloat = 900) -> CGImage? {
        guard let input = try? PhotoIO.load(url) else { return nil }
        let out = Renderer.render(input, r, maxDimension: maxDimension)
        return Renderer.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: PhotoFixture.p3)
    }
}
