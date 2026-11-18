import XCTest
#if os(macOS)
import AppKit
#endif

/// XCUITest suite shared by the iOS and macOS UI test targets. Test names carry workflow IDs
/// (tools/workflow_coverage.py reads them). Launch arguments put the app in a known state;
/// see App/Shared/AppModel.swift `LaunchOptions`.
final class ProofSheetUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let app = app {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .deleteOnSuccess
            add(shot)
        }
    }

    @discardableResult
    func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchArguments = ["-uitest"] + (reset ? ["-uitest-reset"] : []) + extra
        a.launch()
        app = a
        return a
    }

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func wait(_ id: String, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = el(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) never appeared", file: file, line: line)
        return e
    }

    func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = wait(id, file: file, line: line)
        #if os(macOS)
        e.click()
        #else
        e.tap()
        #endif
    }

    /// The text a label shows (iOS puts it in `label`, macOS static texts in `value`).
    func text(_ id: String) -> String {
        let e = wait(id)
        let v = (e.value as? String) ?? ""
        return v.isEmpty ? e.label : v
    }

    func expectText(_ id: String, contains needle: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if text(id).contains(needle) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("\(id) shows '\(text(id))', expected it to contain '\(needle)'", file: file, line: line)
    }

    func segment(_ title: String) {
        #if os(macOS)
        let radio = app.radioButtons[title].firstMatch
        if radio.waitForExistence(timeout: 3) { radio.click(); return }
        app.buttons[title].firstMatch.click()
        #else
        app.buttons[title].firstMatch.tap()
        #endif
    }

    func open(_ name: String) {
        tap("asset.\(name)")
        _ = wait("editor.\(name)")
    }

    func back() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { app.navigationBars.buttons.element(boundBy: 0).tap() }
        #endif
    }

    func step(_ id: String, up: Bool) {
        let s = wait(id)
        #if os(macOS)
        (up ? s.incrementArrows : s.decrementArrows).firstMatch.click()
        #else
        // Stepper halves are found by label ("Increment"/"Decrement"), not identifier.
        let half = s.buttons.matching(NSPredicate(format: "label == %@", up ? "Increment" : "Decrement")).firstMatch
        (half.exists ? half : s.buttons.element(boundBy: up ? 1 : 0)).tap()
        #endif
    }

    // MARK: import

    func test_W01_W03_importPhotoAndVideo() {
        launch(["-inbox", "-access", "full"])
        tap("importButton")
        tap("inbox.Coordinates.jpg")
        _ = wait("asset.Coordinates.jpg")
        tap("importButton")
        tap("inbox.Clip.mov")
        open("Clip.mov")
        expectText("frameCount", contains: "120")
    }

    func test_W02_limitedAccessSelectMore() {
        launch(["-seed", "-access", "limited"])
        expectText("accessBanner", contains: "Limited Access")
        _ = wait("asset.Coordinates.jpg")
        XCTAssertFalse(el("asset.Chart.png").exists, "limited access showed an unselected photo")
        tap("selectMore")
        tap("allow.Chart.png")
        _ = wait("asset.Chart.png")
    }

    #if os(macOS)
    func test_W04_pasteFileFromFinder() throws {
        let url = URL(fileURLWithPath: "/tmp/proofsheet-paste-\(UUID().uuidString.prefix(6)).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        launch(["-access", "full"])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        app.windows.firstMatch.click()
        app.typeKey("v", modifierFlags: .command)
        _ = wait("asset.\(url.lastPathComponent)")
    }
    #endif

    // MARK: photo editing

    func test_W07_W08_W09_adjustCropFilter() {
        launch(["-seed"])
        open("Coordinates.jpg")
        wait("exposureSlider").adjust(toNormalizedSliderPosition: 0.75)
        expectText("recipeSummary", contains: "exposure")
        tap("rotateButton")
        expectText("recipeSummary", contains: "turns 1")
        tap("aspectSquare")
        expectText("recipeSummary", contains: "crop")
        segment("Mono")
        expectText("recipeSummary", contains: "filter mono")
    }

    func test_W10_undoRedoCompare() {
        launch(["-seed"])
        open("Coordinates.jpg")
        wait("exposureSlider").adjust(toNormalizedSliderPosition: 0.8)
        expectText("recipeSummary", contains: "exposure")
        segment("Sepia")
        expectText("recipeSummary", contains: "filter sepia")
        tap("undoButton")
        XCTAssertFalse(text("recipeSummary").contains("sepia"))
        expectText("recipeSummary", contains: "exposure")
        tap("undoButton")
        expectText("recipeSummary", contains: "original")
        tap("redoButton")
        expectText("recipeSummary", contains: "exposure")
        tap("compareButton")
        expectText("compareLabel", contains: "Original")
        tap("compareButton")
        expectText("compareLabel", contains: "Edited")
    }

    func test_W11_revertIsUndoable() {
        launch(["-seed"])
        open("Coordinates.jpg")
        tap("rotateButton")
        segment("Mono")
        tap("revertButton")
        expectText("recipeSummary", contains: "original")
        tap("undoButton")
        expectText("recipeSummary", contains: "filter mono")
    }

    func test_W12_copyAndPasteEdits() {
        launch(["-seed"])
        open("Coordinates.jpg")
        segment("Mono")
        tap("copyEditsButton")
        back()
        tap("pasteEdits")
        _ = wait("edited.Chart.png")
    }

    // MARK: video

    func test_W13_W14_W15_trimSpeedMute() {
        launch(["-seed"])
        open("Clip.mov")
        expectText("frameCount", contains: "120")
        step("trimIn", up: true)
        expectText("frameCount", contains: "110")
        step("trimOut", up: false)
        expectText("frameCount", contains: "100")
        segment("2×")
        expectText("frameCount", contains: "50")
        let mute = wait("muteToggle")
        #if os(macOS)
        mute.click()
        #else
        mute.switches.firstMatch.exists ? mute.switches.firstMatch.tap() : mute.tap()
        #endif
    }

    // MARK: export

    func test_W21_W22_exportAndShare() {
        launch(["-seed"])
        open("Coordinates.jpg")
        tap("exportButton")
        tap("startExport")
        expectText("exportResult", contains: "Coordinates-edited.jpg", timeout: 20)
        tap("shareButton")
        #if os(iOS)
        let sheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || app.cells.count > 0, "share sheet did not appear")
        #else
        let shown = app.menus.firstMatch.waitForExistence(timeout: 5) || app.popovers.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(shown, "sharing picker did not appear")
        #endif
    }

    func test_W23_cancelExportAndFullDisk() {
        launch(["-seed", "-exportDelay", "6"])
        open("Clip.mov")
        tap("exportButton")
        _ = wait("exportProgress")
        tap("cancelExport")
        expectText("exportResult", contains: "cancelled")
        app.terminate()
        launch(["-seed", "-diskFree", "1000"])
        open("Coordinates.jpg")
        tap("exportButton")
        tap("startExport")
        expectText("exportError", contains: "Not enough storage")
    }

    // MARK: cloud + platform

    func test_W26_offlineEditsQueue() {
        launch(["-seed", "-offline"])
        open("Coordinates.jpg")
        tap("rotateButton")
        back()
        expectText("pendingBadge", contains: "Pending sync: 1")
        open("Chart.png")
        tap("rotateButton")
        back()
        expectText("pendingBadge", contains: "Pending sync: 2")
    }

    func test_W36_deepLinkOpensAsset() throws {
        launch(["-seed"])
        let id = wait("asset.Chart.png").value as? String ?? ""
        XCTAssertFalse(id.isEmpty, "row carries no asset id")
        if #available(iOS 16.4, macOS 13.3, *) {
            app.open(URL(string: "proofsheet://asset/\(id)")!)
            _ = wait("editor.Chart.png")
        } else {
            throw XCTSkip("XCUIApplication.open(URL) needs iOS 16.4 / macOS 13.3")
        }
    }

    func test_W37_autosaveSurvivesRelaunch() {
        launch(["-seed"])
        open("Coordinates.jpg")
        tap("rotateButton")
        expectText("recipeSummary", contains: "turns 1")
        app.terminate()
        launch([], reset: false)
        open("Coordinates.jpg")
        expectText("recipeSummary", contains: "turns 1")
    }

    func test_W38_accessRevokedMidSession() {
        launch(["-seed", "-offline"])
        open("Coordinates.jpg")
        tap("rotateButton")
        back()
        expectText("pendingBadge", contains: "Pending sync: 1")
        tap("simulateRevoke")
        expectText("accessBanner", contains: "No Photos Access")
        XCTAssertFalse(el("asset.Coordinates.jpg").exists, "assets still shown after access was revoked")
        expectText("pendingBadge", contains: "Pending sync: 1")
    }

    func test_W39_accessibilityAudit() throws {
        guard #available(iOS 17.0, macOS 14.0, *) else { throw XCTSkip("performAccessibilityAudit needs iOS 17 / macOS 14") }
        #if os(iOS)
        launch(["-seed", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        #else
        launch(["-seed"])
        #endif
        try audit("library")
        open("Coordinates.jpg")
        try audit("editor")
    }

    /// Run the audit and report every issue with its element, so a failure says what to fix.
    /// The two zero-size probes exist only so tests can read appearance and layout direction.
    @available(iOS 17.0, macOS 14.0, *)
    func audit(_ screen: String) throws {
        var problems: [String] = []
        try app.performAccessibilityAudit { issue in
            let id = issue.element?.identifier ?? ""
            if id == "appearanceProbe" || id == "layoutProbe" { return true }
            problems.append("[\(screen)] \(issue.compactDescription): id='\(id)' label='\(issue.element?.label ?? "")' type=\(issue.element?.elementType.rawValue ?? 0)")
            return true
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    func test_W40_rightToLeftAndLongStrings() {
        launch(["-seed", "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"])
        expectText("layoutProbe", contains: "rightToLeft")
        XCTAssertTrue(app.staticTexts["المكتبة"].waitForExistence(timeout: 5) || app.navigationBars["المكتبة"].exists
                      || app.windows["المكتبة"].exists, "Arabic title missing")
        app.terminate()
        launch(["-seed", "-NSDoubleLocalizedStrings", "YES"])
        open("Coordinates.jpg")
        let export = wait("exportButton")
        for _ in 0..<6 where !export.isHittable { app.swipeUp() }
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(export.isHittable && window.contains(export.frame),
                      "doubled strings pushed Export off screen: \(export.frame) in \(window)")
    }

    func test_W41_darkAppearance() {
        #if os(iOS)
        // Set the system appearance before launch: changing it under a running app is not
        // delivered reliably on every simulator runtime.
        XCUIDevice.shared.appearance = .dark
        launch(["-seed"])
        expectText("appearanceProbe", contains: "dark")
        XCUIDevice.shared.appearance = .light
        expectText("appearanceProbe", contains: "light")
        #else
        launch(["-seed", "-AppleInterfaceStyle", "Dark"])
        expectText("appearanceProbe", contains: "dark")
        #endif
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "appearance"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func test_W42_multitaskingLayout() throws {
        launch(["-seed"])
        #if os(macOS)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5), "Cmd-N did not open a second window")
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout test runs on the iPad destination") }
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = wait("importButton")
        _ = wait("emptyEditor")
        open("Coordinates.jpg")
        _ = wait("importButton")
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    func test_W43_launchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let a = XCUIApplication()
            a.launchArguments = ["-uitest"]
            a.launch()
        }
    }

    func test_W45_upgradeKeepsLibraryAndUnsyncedEdits() {
        launch(["-seedV1"])
        _ = wait("asset.Beach.jpg")
        _ = wait("asset.Portrait.jpg")
        _ = wait("edited.Beach.jpg")
        expectText("pendingBadge", contains: "Pending sync: 1")
        open("Beach.jpg")
        expectText("recipeSummary", contains: "exposure 0.50")
        expectText("recipeSummary", contains: "crop 0.50x0.50")
    }
}
