import CoreImage
import ProofChecks
import ProofKit
import XCTest

/// Each client-side fault must fail exactly its pinned checks. Server-side faults need the server
/// restarted with PROOF_FAULTS, so tools/fault_matrix.py covers those.
final class FaultMatrixTests: XCTestCase {
    func failing(with fault: Fault) -> Set<String> {
        let saved = FaultInjection.active
        FaultInjection.active = [fault]
        defer { FaultInjection.active = saved }
        var failed = Set<String>()
        for c in Checks.all {
            do { try c.run() } catch { failed.insert(c.name) }
        }
        return failed
    }

    func testEveryClientFaultIsCaughtByExactlyItsChecks() {
        for fault in Fault.allCases where !Fault.serverSide.contains(fault) {
            XCTAssertEqual(failing(with: fault), Checks.expectedFailures[fault], "\(fault)")
        }
    }

    func testEveryFaultHasPinnedExpectations() {
        for fault in Fault.allCases {
            XCTAssertFalse(Checks.expectedFailures[fault, default: []].isEmpty, "\(fault) is caught by nothing")
        }
    }
}

final class WorkflowCoverageTests: XCTestCase {
    func testCheckTestsMatchChecks() {
        let declared = Set(Checks.all.map { "test_" + $0.name.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_") })
        let methods = Set(CheckTests.defaultTestSuite.tests.compactMap { $0.name.split(separator: " ").last?.dropLast().description })
        XCTAssertEqual(declared, methods)
    }
}

/// W43 with XCTest's own metrics (baselines live in Xcode's .xcbaseline once recorded on a machine).
final class PerformanceTests: XCTestCase {
    func testProxyRenderTimeAndMemory() throws {
        let input = CIImage(cgImage: PhotoFixture.coordinateImage())
        var r = PhotoRecipe()
        r.exposure = 0.3; r.filter = .sepia; r.straighten = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]) {
            _ = Pixels(Renderer.render(input, r, maxDimension: 600))
        }
    }

    func testFullResolutionHEICExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("src.tiff")
        try PhotoIO.write(PhotoFixture.coordinateImage(), to: src, format: .tiff)
        measure(metrics: [XCTClockMetric(), XCTStorageMetric()]) {
            try? PhotoIO.export(src, recipe: PhotoRecipe(), preset: PhotoExportPreset(format: .heic), to: dir.appendingPathComponent("o.heic"))
        }
    }
}
