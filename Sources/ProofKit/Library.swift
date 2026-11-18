import AVFoundation
import CryptoKit
import Foundation
import ImageIO

public enum AssetKind: String, Codable { case photo, video, livePhoto }

public struct Asset: Codable, Equatable, Identifiable {
    /// First 16 hex chars of the original's SHA-256: the same file imported twice is one asset.
    public var id: String
    public var name: String
    public var kind: AssetKind
    /// File name inside the library's Originals folder.
    public var file: String
    public var pairedMovie: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var photo: PhotoRecipe?
    public var video: VideoRecipe?
    public var cloudETag: String?
    public var reviewStatus: String?

    public init(id: String, name: String, kind: AssetKind, file: String, pairedMovie: String?, pixelWidth: Int, pixelHeight: Int,
                photo: PhotoRecipe?, video: VideoRecipe?, cloudETag: String?, reviewStatus: String?) {
        self.id = id; self.name = name; self.kind = kind; self.file = file; self.pairedMovie = pairedMovie
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.photo = photo; self.video = video
        self.cloudETag = cloudETag; self.reviewStatus = reviewStatus
    }

    public var isEdited: Bool {
        if let p = photo, !p.isIdentity { return true }
        return video != nil
    }
}

public struct PendingOp: Codable, Equatable {
    public enum Kind: String, Codable { case upload, recipe, delete }
    public var assetID: String
    public var kind: Kind
    public init(assetID: String, kind: Kind) { self.assetID = assetID; self.kind = kind }
}

public struct LibraryFile: Codable, Equatable {
    public static let currentSchema = 2
    public var schema = LibraryFile.currentSchema
    public var assets: [Asset] = []
    public var pending: [PendingOp] = []
    public init() {}
}

/// What PhotoKit authorization allows the app to show. Driven by PHAuthorizationStatus in the
/// app; modelled here so every state is testable without the system prompt.
public enum LibraryAccess: Equatable {
    case notDetermined, full, denied
    case limited(Set<String>)

    public func visible(_ assets: [Asset]) -> [Asset] {
        switch self {
        case .full: return assets
        case .limited(let ids): return assets.filter { ids.contains($0.id) }
        case .notDetermined, .denied: return []
        }
    }

    public var banner: String? {
        switch self {
        case .limited: return "Limited Access"
        case .denied: return "No Photos Access"
        case .notDetermined: return "Allow Access"
        case .full: return nil
        }
    }
}

public enum LibraryError: Error { case unsupported(String), corrupt(String) }

public enum LibraryStore {
    public static func load(_ url: URL) throws -> LibraryFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryFile() }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if obj["version"] as? Int == 1 { return try migrateV1(obj) }
        return try JSONDecoder().decode(LibraryFile.self, from: data)
    }

    public static func save(_ lib: LibraryFile, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(lib).write(to: url, options: .atomic)
    }

    /// v1 stored exposure as "ev", crop in PIXELS, and the sync queue as bare IDs.
    static func migrateV1(_ obj: [String: Any]) throws -> LibraryFile {
        var lib = LibraryFile()
        for item in obj["items"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, let file = item["file"] as? String,
                  let w = item["width"] as? Int, let h = item["height"] as? Int else { throw LibraryError.corrupt("v1 item") }
            var r = PhotoRecipe()
            r.exposure = item["ev"] as? Double ?? 0
            if let c = item["crop"] as? [Double], c.count == 4 {
                r.crop = NormalizedRect(x: c[0] / Double(w), y: c[1] / Double(h), w: c[2] / Double(w), h: c[3] / Double(h))
            }
            lib.assets.append(Asset(id: id, name: item["name"] as? String ?? file, kind: .photo, file: file, pairedMovie: nil,
                                    pixelWidth: w, pixelHeight: h, photo: r, video: nil, cloudETag: nil, reviewStatus: nil))
        }
        if !FaultInjection.on(.migrationDropsPending) {
            lib.pending = (obj["queue"] as? [String] ?? []).map { PendingOp(assetID: $0, kind: .recipe) }
        }
        return lib
    }
}

public enum Importer {
    static let photoExts: Set<String> = ["jpg", "jpeg", "heic", "png", "tif", "tiff", "dng"]
    static let movieExts: Set<String> = ["mov", "mp4", "m4v"]

    public static func contentID(_ url: URL) throws -> String {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: d).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Import files (Files app, drag and drop, paste, picker). Copies originals into `originals`,
    /// pairs Live Photos, skips duplicates already in `existing`.
    public static func importFiles(_ urls: [URL], into originals: URL, existing: [Asset]) throws -> [Asset] {
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let stills = urls.filter { photoExts.contains($0.pathExtension.lowercased()) }
        let movies = urls.filter { movieExts.contains($0.pathExtension.lowercased()) }
        for u in urls where !photoExts.contains(u.pathExtension.lowercased()) && !movieExts.contains(u.pathExtension.lowercased()) {
            throw LibraryError.unsupported(u.lastPathComponent)
        }
        let pairs = LivePhoto.pair(stills: stills, movies: movies)
        let pairedMovies = Set(pairs.map { $0.movie })
        var seen = Set(existing.map { $0.id })
        var out: [Asset] = []

        func copy(_ u: URL, id: String) throws -> String {
            let name = "\(id).\(u.pathExtension.lowercased())"
            let dest = originals.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: u, to: dest) }
            return name
        }

        for s in stills {
            let id = try contentID(s)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let p = PhotoIO.properties(s)
            var w = p[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            if let o = p[kCGImagePropertyOrientation as String] as? Int, o >= 5 { swap(&w, &h) }
            let movie = pairs.first { $0.still == s }?.movie
            out.append(Asset(id: id, name: s.lastPathComponent, kind: movie == nil ? .photo : .livePhoto, file: try copy(s, id: id),
                             pairedMovie: try movie.map { try copy($0, id: id + "-motion") }, pixelWidth: w, pixelHeight: h,
                             photo: PhotoRecipe(), video: nil, cloudETag: nil, reviewStatus: nil))
        }
        for m in movies where !pairedMovies.contains(m) {
            let id = try contentID(m)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let size = AVURLAsset(url: m).tracks(withMediaType: .video).first?.naturalSize ?? .zero
            out.append(Asset(id: id, name: m.lastPathComponent, kind: .video, file: try copy(m, id: id), pairedMovie: nil,
                             pixelWidth: Int(size.width), pixelHeight: Int(size.height), photo: nil, video: nil, cloudETag: nil, reviewStatus: nil))
        }
        return out
    }
}

/// Handoff and deep links: the same edit opens on the other device, mid-edit.
public enum Continuity {
    public static let activityType = "com.proofsheet.edit"
    public static let scheme = "proofsheet"

    public static func userInfo(assetID: String, recipe: PhotoRecipe) throws -> [String: Any] {
        ["assetID": assetID, "recipe": String(data: try JSONEncoder().encode(recipe), encoding: .utf8)!]
    }

    public static func decode(_ info: [AnyHashable: Any]) -> (assetID: String, recipe: PhotoRecipe)? {
        guard let id = info["assetID"] as? String, let json = info["recipe"] as? String,
              let r = try? JSONDecoder().decode(PhotoRecipe.self, from: Data(json.utf8)) else { return nil }
        return (id, r)
    }

    public static func url(assetID: String) -> URL { URL(string: "\(scheme)://asset/\(assetID)")! }

    /// proofsheet://asset/<id> -> id. Anything else -> nil (never crash on a bad link).
    public static func assetID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "asset" else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        return id.range(of: "^[0-9a-zA-Z_-]{1,64}$", options: .regularExpression) == nil ? nil : id
    }
}
