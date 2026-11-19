import AVFoundation
import CoreGraphics
import Foundation
import ProofChecks
import ProofKit

/// ps check [name...]   run checks (all by default)
/// ps faults             run the fault matrix: each fault must fail exactly its pinned checks
/// ps list               check -> workflows
/// ps json               checks as JSON (for tools/workflow_coverage.py)
/// ps device <server> <device> <action> ...   act as one device against cloud/server.py (pytest E2E):
///     upload <file>                          -> prints asset id
///     edit <id> <exposure> <filter> <proxyW> <proxyH> <x> <y> <w> <h>   crop drawn on a proxy, in proxy pixels
///     render <id> <out.jpg>                  pull original + recipe, render, push the rendition
///     share <id>                             -> prints share token
///     status <id>                            -> prints review status
let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "check"

struct CaseResult { let name: String; let workflows: [String]; let seconds: Double; let failure: String? }
var results: [CaseResult] = []

func runChecks(_ names: [String]) -> [String] {
    var failed: [String] = []
    for c in Checks.all where names.isEmpty || names.contains(c.name) {
        let t = Date()
        do {
            try c.run()
            let s = Date().timeIntervalSince(t)
            results.append(CaseResult(name: c.name, workflows: c.workflows, seconds: s, failure: nil))
            print(String(format: "  PASS  %-32@ %@  %.1fs", c.name, c.workflows.joined(separator: ","), s))
        } catch {
            failed.append(c.name)
            results.append(CaseResult(name: c.name, workflows: c.workflows, seconds: Date().timeIntervalSince(t), failure: "\(error)"))
            print(String(format: "  FAIL  %-32@ %@  %@", c.name, c.workflows.joined(separator: ","), "\(error)"))
        }
        fflush(stdout)
    }
    return failed
}

/// JUnit XML so Jenkins (and Xcode Cloud / GitHub) show each workflow check as its own test.
func writeJUnit(_ path: String) {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    let fails = results.filter { $0.failure != nil }.count
    var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    x += "<testsuite name=\"proof-sheet workflow checks\" tests=\"\(results.count)\" failures=\"\(fails)\" time=\"\(results.reduce(0) { $0 + $1.seconds })\">\n"
    for r in results {
        x += "  <testcase classname=\"workflows.\(esc(r.workflows.joined(separator: "_")))\" name=\"\(esc(r.name))\" time=\"\(String(format: "%.3f", r.seconds))\">"
        if let f = r.failure { x += "<failure message=\"\(esc(f))\"/>" }
        x += "</testcase>\n"
    }
    x += "</testsuite>\n"
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? x.write(toFile: path, atomically: true, encoding: .utf8)
}

switch cmd {
case "check":
    var rest = Array(args.dropFirst())
    var junit: String?
    if let i = rest.firstIndex(of: "--junit"), i + 1 < rest.count { junit = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
    let names = rest
    let failed = runChecks(names)
    if let j = junit { writeJUnit(j) }
    let total = names.isEmpty ? Checks.all.count : names.count
    print("\(total - failed.count)/\(total) checks passed" + (FaultInjection.active.isEmpty ? "" : "  [faults: \(FaultInjection.active.map { $0.rawValue }.sorted().joined(separator: ","))]"))
    exit(failed.isEmpty ? 0 : 1)
case "failing":
    // Used by the fault matrix: prints only the names that failed.
    for n in runChecks([]) { print("FAILED \(n)") }
case "list":
    for c in Checks.all { print("\(c.name)\t\(c.workflows.joined(separator: ","))") }
case "json":
    let rows = Checks.all.map { ["name": $0.name, "workflows": $0.workflows] as [String: Any] }
    let expected = Dictionary(uniqueKeysWithValues: Checks.expectedFailures.map { ($0.key.rawValue, $0.value.sorted()) })
    let data = try! JSONSerialization.data(withJSONObject: ["checks": rows, "expectedFailures": expected], options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
case "fixtures":
    // ps fixtures <dir>: camera.jpg (1200x800 coordinate image with EXIF/GPS) and clip-h264.mp4 (90 frames, web-playable).
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".build/proof-work")
    let fx = try! Fixtures(dir: dir)
    let jpg = try! fx.cameraJPEG()
    let h264 = dir.appendingPathComponent("clip-h264.mp4")
    if !FileManager.default.fileExists(atPath: h264.path) {
        let b = try! VideoEditor.build(VideoRecipe(segments: [ClipSegment(0, 90)]), source: try! fx.clip())
        try! VideoExport.export(b, preset: VideoExportPreset.all[0], to: h264, fileType: .mp4)
    }
    print(jpg.path); print(h264.path)
case "device":
    guard args.count >= 4, let base = URL(string: args[1]) else { print("usage: ps device <server> <device> <action> ..."); exit(2) }
    let client = SyncClient(base: base, device: args[2])
    let a = Array(args.dropFirst(3))
    do {
        switch a[0] {
        case "upload":
            let file = URL(fileURLWithPath: a[1])
            let id = try Importer.contentID(file)
            try client.upload(file, id: id, name: file.lastPathComponent, kind: .photo)
            print(id)
        case "edit":
            let remote = try client.recipe(a[1])
            var r = remote.recipe ?? PhotoRecipe()
            r.exposure = Double(a[2])!
            r.filter = PhotoFilter(rawValue: a[3])!
            let n = a[4...9].map { CGFloat(Double($0)!) }
            let original = try client.original(a[1])
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ps-\(a[1])")
            try original.write(to: tmp)
            let full = try PhotoIO.load(tmp).extent.size
            r.crop = NormalizedRect.from(pixelRect: CGRect(x: n[2], y: n[3], width: n[4], height: n[5]),
                                         shownSize: CGSize(width: n[0], height: n[1]), fullSize: full)
            print(try client.putRecipe(a[1], r, ifMatch: remote.etag))
        case "render":
            let remote = try client.recipe(a[1])
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ps-orig-\(a[1])")
            try client.original(a[1]).write(to: tmp)
            let out = URL(fileURLWithPath: a[2])
            try PhotoIO.export(tmp, recipe: remote.recipe ?? PhotoRecipe(), preset: PhotoExportPreset(format: .jpeg, gamut: .srgb), to: out)
            try client.putRendition(a[1], data: Data(contentsOf: out))
            print(out.path)
        case "share":
            print(try client.share(a[1]))
        case "status":
            print(try client.recipe(a[1]).review)
        default:
            print("unknown device action \(a[0])"); exit(2)
        }
    } catch {
        print("error: \(error)"); exit(1)
    }
default:
    print("usage: ps [check [name...] | failing | list | json]")
    exit(2)
}
