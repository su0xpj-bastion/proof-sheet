import CoreImage
import Foundation
import ProofKit

public struct CheckFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Fail the check with `message` unless `ok`.
func expect(_ ok: Bool, _ message: @autoclosure () throws -> String) throws {
    if !ok { throw CheckFailure(try message()) }
}

func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

func fmt(_ v: [Double]) -> String { "(" + v.map { String(format: "%.3f", $0) }.joined(separator: ", ") + ")" }
func fmt(_ p: (Double, Double)) -> String { String(format: "(%.3f, %.3f)", p.0, p.1) }

/// Where the repo lives: PROOF_REPO, else three levels up from this source file.
public let repoRoot: URL = {
    if let r = ProcessInfo.processInfo.environment["PROOF_REPO"] { return URL(fileURLWithPath: r) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}()

/// cloud/server.py on a free port, started once per process and killed at exit.
public final class CloudServer {
    public static let shared = CloudServer()
    private var process: Process?
    private var url: URL?

    public func baseURL() throws -> URL {
        if let u = url { return u }
        if let env = ProcessInfo.processInfo.environment["PROOF_SERVER_URL"] {
            url = URL(string: env)!
            return url!
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", repoRoot.appendingPathComponent("cloud/server.py").path, "--port", "0"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        process = p
        atexit { CloudServer.shared.stop() }
        var line = Data()
        let handle = out.fileHandleForReading
        while !line.contains(UInt8(ascii: "\n")) {
            let d = handle.availableData
            if d.isEmpty { throw CheckFailure("server exited before listening") }
            line += d
        }
        let text = String(data: line, encoding: .utf8) ?? ""
        guard let port = text.split(separator: " ").last.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            throw CheckFailure("server said: \(text)")
        }
        url = URL(string: "http://127.0.0.1:\(port)")!
        return url!
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    /// Test-only controls: reset state, set quota / token TTL / injected 503s.
    public func admin(_ path: String, _ body: [String: Any] = [:]) throws {
        var req = URLRequest(url: try baseURL().appendingPathComponent("_admin/\(path)"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: req) { _, r, _ in status = (r as? HTTPURLResponse)?.statusCode ?? 0; done.signal() }.resume()
        done.wait()
        try expect(status == 200, "admin \(path) -> \(status)")
    }

    /// Unauthenticated GET/POST as a browser would make it (review pages).
    public func browser(_ method: String, _ path: String, json: [String: Any]? = nil, cookie: String? = nil) throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: path, relativeTo: try baseURL())!)
        req.httpMethod = method
        if let j = json {
            req.httpBody = try JSONSerialization.data(withJSONObject: j)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let c = cookie { req.setValue(c, forHTTPHeaderField: "Cookie") }
        let done = DispatchSemaphore(value: 0)
        var result = (0, Data())
        URLSession.shared.dataTask(with: req) { d, r, _ in
            result = ((r as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data()); done.signal()
        }.resume()
        done.wait()
        return result
    }
}

/// Fixtures written once per work directory and reused across checks and fault runs.
public final class Fixtures {
    public let dir: URL

    public init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public static let shared: Fixtures = {
        let env = ProcessInfo.processInfo.environment["PROOF_WORK"]
        let d = env.map { URL(fileURLWithPath: $0) } ?? repoRoot.appendingPathComponent(".build/proof-work")
        return try! Fixtures(dir: d)
    }()

    public func scratch(_ name: String) throws -> URL {
        let u = dir.appendingPathComponent("scratch/\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func cached(_ name: String, _ make: (URL) throws -> Void) throws -> URL {
        let u = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: u.path) {
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)-\(name)")
            try make(tmp)
            try? FileManager.default.removeItem(at: u)
            try FileManager.default.moveItem(at: tmp, to: u)
        }
        return u
    }

    /// Coordinate image as a camera JPEG: EXIF, TIFF maker, GPS.
    public func cameraJPEG() throws -> URL {
        try cached("camera.jpg") { try PhotoIO.write(PhotoFixture.coordinateImage(), to: $0, format: .jpeg, properties: PhotoFixture.cameraMetadata) }
    }

    /// Same pixels, stored landscape but tagged Orientation 6 (shown rotated 90 degrees clockwise).
    public func orientedJPEG() throws -> URL {
        try cached("oriented.jpg") {
            try PhotoIO.write(PhotoFixture.coordinateImage(), to: $0, format: .jpeg, properties: [kCGImagePropertyOrientation as String: 6])
        }
    }

    public func coordinate16TIFF() throws -> URL {
        try cached("coord16.tiff") { try PhotoIO.write(PhotoFixture.coordinateImage(), to: $0, format: .tiff) }
    }

    public func chartPNG() throws -> URL {
        try cached("chart-p3.png") { try PhotoIO.write(PhotoFixture.colorChart(), to: $0, format: .png) }
    }

    public func hdrTIFF() throws -> URL {
        try cached("hdr.tiff") { try PhotoIO.write(PhotoFixture.hdrImage(), to: $0, format: .tiff) }
    }

    /// 300 frames at 29.97 with frame codes and clicks (~10 s to write, so cached).
    public func clip() throws -> URL {
        try cached("clip.mov") { try VideoFixture.write(frames: 300, to: $0) }
    }

    public static let liveID = "6F0C7E2A-3B1D-4C59-9E44-7A51B2D0C001"

    /// A Live Photo pair whose files do NOT share a name, plus a decoy movie that does.
    public func livePhoto() throws -> (still: URL, movie: URL, decoy: URL) {
        let still = try cached("IMG_0042.heic") {
            try PhotoIO.write(PhotoFixture.coordinateImage(width: 600, height: 400), to: $0, format: .heic,
                              properties: LivePhoto.stillProperties(id: Fixtures.liveID))
        }
        let movie = try cached("IMG_0042_motion_export.mov") { try VideoFixture.write(frames: 45, to: $0, contentID: Fixtures.liveID) }
        let decoy = try cached("IMG_0042.mov") { try VideoFixture.write(frames: 30, to: $0, contentID: "00000000-0000-0000-0000-00000000DEAD") }
        return (still, movie, decoy)
    }
}
