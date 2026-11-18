import CryptoKit
import Foundation

public enum SyncError: Error, Equatable {
    case offline
    case conflict(serverETag: String)
    case quotaExceeded
    case unauthorized
    case http(Int, String)
    case checksumRejected
}

/// Client for cloud/server.py. Synchronous on purpose: the app calls it off the main thread,
/// and checks read top to bottom.
public final class SyncClient {
    public let base: URL
    public let device: String
    public var maxAttempts = 4
    /// Seconds; real apps use ~1 s, tests shrink it.
    public var backoffBase = 0.05
    public private(set) var retries = 0
    public private(set) var bytesSent = 0
    private var token: String?
    private let session: URLSession

    public init(base: URL, device: String) {
        self.base = base
        self.device = device
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        session = URLSession(configuration: cfg)
    }

    // MARK: transport

    struct Response { let status: Int; let data: Data; let headers: [AnyHashable: Any] }

    private func raw(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:], auth: Bool = true) throws -> Response {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        req.httpBody = body
        if body != nil && headers["Content-Type"] == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if auth, let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        var result: Response?, failure: Error?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            if let http = resp as? HTTPURLResponse {
                result = Response(status: http.statusCode, data: data ?? Data(), headers: http.allHeaderFields)
            } else {
                failure = err
            }
            done.signal()
        }.resume()
        done.wait()
        guard let r = result else {
            if let e = failure as? URLError, [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(e.code) {
                throw SyncError.offline
            }
            throw failure ?? SyncError.offline
        }
        return r
    }

    /// Auth refresh on 401 (once), jittered exponential backoff on 503.
    func request(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) throws -> Response {
        if token == nil { try authenticate() }
        var refreshed = false
        var attempt = 0
        while true {
            let r = try raw(method, path, body: body, headers: headers)
            if r.status == 401 && !refreshed {
                refreshed = true
                try authenticate()
                continue
            }
            if r.status == 503 && !FaultInjection.on(.noRetryOn503) && attempt + 1 < maxAttempts {
                retries += 1
                Thread.sleep(forTimeInterval: backoffBase * pow(2, Double(attempt)) + Double.random(in: 0..<backoffBase))
                attempt += 1
                continue
            }
            switch r.status {
            case 200..<300: return r
            case 401: throw SyncError.unauthorized
            case 412: throw SyncError.conflict(serverETag: r.headers["Etag"] as? String ?? r.headers["ETag"] as? String ?? "")
            case 507: throw SyncError.quotaExceeded
            case 422: throw SyncError.checksumRejected
            default: throw SyncError.http(r.status, String(data: r.data, encoding: .utf8) ?? "")
            }
        }
    }

    func json(_ r: Response) throws -> Any { try JSONSerialization.jsonObject(with: r.data) }
    func encode(_ obj: Any) throws -> Data { try JSONSerialization.data(withJSONObject: obj) }

    public func authenticate() throws {
        let r = try raw("POST", "/auth/token", body: try encode(["device": device]), auth: false)
        guard r.status == 200, let obj = try json(r) as? [String: Any], let t = obj["token"] as? String else {
            throw SyncError.http(r.status, "auth")
        }
        token = t
    }

    // MARK: upload

    public struct UploadInterrupted: Error { public let afterChunks: Int }

    /// Chunked upload that resumes: asks the server which chunks it has, sends only the rest,
    /// then commits with the file's SHA-256 so a corrupt transfer is rejected, not stored.
    @discardableResult
    public func upload(_ file: URL, id: String, name: String, kind: AssetKind, chunkSize: Int = 256 * 1024,
                       interruptAfter: Int? = nil) throws -> String {
        let data = try Data(contentsOf: file)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let created = try request("POST", "/assets", body: try encode([
            "id": id, "name": name, "kind": kind.rawValue, "size": data.count, "sha256": sha, "chunk_size": chunkSize, "device": device,
        ]))
        if (try json(created) as? [String: Any])?["existing"] as? Bool == true { return "\"v0\"" }
        let status = try json(try request("GET", "/assets/\(id)/upload")) as? [String: Any]
        let have = Set(status?["received"] as? [Int] ?? [])
        let count = (data.count + chunkSize - 1) / chunkSize
        var sent = 0
        for i in 0..<count where !have.contains(i) {
            if let stop = interruptAfter, sent == stop { throw UploadInterrupted(afterChunks: sent) }
            let chunk = data.subdata(in: (i * chunkSize)..<min(data.count, (i + 1) * chunkSize))
            _ = try request("PUT", "/assets/\(id)/chunks/\(i)", body: chunk, headers: ["Content-Type": "application/octet-stream"])
            bytesSent += chunk.count
            sent += 1
        }
        let r = try request("POST", "/assets/\(id)/commit")
        return (try json(r) as? [String: Any])?["etag"] as? String ?? ""
    }

    public func putRendition(_ id: String, data: Data) throws {
        _ = try request("PUT", "/assets/\(id)/rendition", body: data, headers: ["Content-Type": "application/octet-stream"])
    }

    public func original(_ id: String) throws -> Data { try request("GET", "/assets/\(id)/original").data }

    // MARK: recipes

    public struct Remote: Equatable {
        public let recipe: PhotoRecipe?
        public let etag: String
        public let review: String
    }

    public func recipe(_ id: String) throws -> Remote {
        let r = try request("GET", "/assets/\(id)/recipe")
        let obj = try json(r) as? [String: Any] ?? [:]
        var recipe: PhotoRecipe?
        if let rec = obj["recipe"], !(rec is NSNull) {
            recipe = try JSONDecoder().decode(PhotoRecipe.self, from: try encode(rec))
        }
        let tag = r.headers["Etag"] as? String ?? r.headers["ETag"] as? String ?? ""
        return Remote(recipe: recipe, etag: tag, review: obj["review"] as? String ?? "")
    }

    /// Write only if nobody else has since `ifMatch`; otherwise `.conflict`.
    @discardableResult
    public func putRecipe(_ id: String, _ recipe: PhotoRecipe, ifMatch: String) throws -> String {
        let body = try encode(["recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)), "device": device])
        let r = try request("PUT", "/assets/\(id)/recipe", body: body, headers: ["If-Match": ifMatch])
        return r.headers["Etag"] as? String ?? r.headers["ETag"] as? String ?? ""
    }

    public func versions(_ id: String) throws -> [(version: Int, device: String?)] {
        let rows = try json(try request("GET", "/assets/\(id)/versions")) as? [[String: Any]] ?? []
        return rows.map { ($0["version"] as? Int ?? -1, $0["device"] as? String) }
    }

    public func restoreVersion(_ id: String, _ n: Int) throws {
        _ = try request("POST", "/assets/\(id)/versions/\(n)/restore")
    }

    /// "Keep both": the losing edit becomes its own asset instead of being dropped.
    public func duplicate(_ id: String, with recipe: PhotoRecipe) throws -> String {
        let body = try encode(["recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)), "device": device])
        return (try json(try request("POST", "/assets/\(id)/duplicate", body: body)) as? [String: Any])?["id"] as? String ?? ""
    }

    // MARK: library

    public func list(deleted: Bool = false) throws -> [String] {
        let rows = try json(try request("GET", "/assets?deleted=\(deleted ? 1 : 0)")) as? [[String: Any]] ?? []
        return rows.compactMap { $0["id"] as? String }.sorted()
    }

    public func delete(_ id: String) throws { _ = try request("DELETE", "/assets/\(id)") }
    public func restore(_ id: String) throws { _ = try request("POST", "/assets/\(id)/restore") }

    public func share(_ id: String, expiresIn: Double? = nil, password: String? = nil) throws -> String {
        var body: [String: Any] = [:]
        if let e = expiresIn { body["expires_in"] = e }
        if let p = password { body["password"] = p }
        return (try json(try request("POST", "/assets/\(id)/share", body: try encode(body))) as? [String: Any])?["token"] as? String ?? ""
    }

    public func revoke(_ token: String) throws { _ = try request("DELETE", "/share/\(token)") }
}

/// Edits made offline wait here, one entry per asset (the latest recipe wins locally),
/// each remembering the server version it was based on.
public struct OfflineQueue: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var assetID: String
        public var recipe: PhotoRecipe
        public var baseETag: String
    }

    public enum Resolution { case keepBoth, keepServer }

    public private(set) var entries: [Entry] = []
    public init() {}

    public mutating func enqueue(_ id: String, _ recipe: PhotoRecipe, base: String) {
        if let i = entries.firstIndex(where: { $0.assetID == id }) {
            entries[i].recipe = recipe
        } else {
            entries.append(Entry(assetID: id, recipe: recipe, baseETag: base))
        }
    }

    public struct FlushReport: Equatable {
        public var pushed: [String] = []
        public var conflicts: [String] = []
        public var copies: [String] = []
    }

    /// Push in order. A conflict never overwrites the other device's edit.
    public mutating func flush(_ client: SyncClient, resolution: Resolution = .keepBoth) throws -> FlushReport {
        var report = FlushReport()
        while let e = entries.first {
            do {
                try client.putRecipe(e.assetID, e.recipe, ifMatch: e.baseETag)
                report.pushed.append(e.assetID)
            } catch SyncError.conflict {
                report.conflicts.append(e.assetID)
                if resolution == .keepBoth { report.copies.append(try client.duplicate(e.assetID, with: e.recipe)) }
            }
            entries.removeFirst()
        }
        return report
    }

    public func save(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    public static func load(_ url: URL) -> OfflineQueue {
        (try? JSONDecoder().decode(OfflineQueue.self, from: Data(contentsOf: url))) ?? OfflineQueue()
    }
}
