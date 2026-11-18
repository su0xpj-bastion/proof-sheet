import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import ProofKit

/// One named, workflow-tagged check. Throws CheckFailure with what was seen vs expected.
public struct Check {
    public let name: String
    public let workflows: [String]
    public let run: () throws -> Void
}

public enum Checks {
    static var fx: Fixtures { Fixtures.shared }
    static var server: CloudServer { CloudServer.shared }

    public static func run(_ name: String) throws {
        guard let c = all.first(where: { $0.name == name }) else { throw CheckFailure("no check \(name)") }
        try c.run()
    }

    static func client(_ device: String) throws -> SyncClient {
        let c = SyncClient(base: try server.baseURL(), device: device)
        c.backoffBase = 0.01
        return c
    }

    static func corners(_ img: CIImage) -> [(Double, Double)] { Pixels(img).cornerSources() }

    static func cornersMatch(_ got: [(Double, Double)], _ want: [(Double, Double)], tol: Double) -> Bool {
        zip(got, want).allSatisfy { near($0.0, $1.0, tol) && near($0.1, $1.1, tol) }
    }

    /// Corner sources expected for a crop of an upright, unrotated coordinate image.
    static func cropCorners(_ c: NormalizedRect) -> [(Double, Double)] {
        [(c.x, c.y), (c.x + c.w, c.y), (c.x, c.y + c.h), (c.x + c.w, c.y + c.h)]
    }

    static func patch(_ img: CIImage, _ p: PhotoFixture.Patch, _ space: CGColorSpace = PhotoFixture.linearSRGB) -> [Double] {
        Pixels(img, space: space).rgb(Int(p.center.x), Int(p.center.y), r: 10)
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    public static let all: [Check] = importChecks + editChecks + videoChecks + colorChecks + exportChecks + syncChecks + platformChecks

    // MARK: import

    static let importChecks: [Check] = [
        Check(name: "import.formats", workflows: ["W05"]) {
            let dir = try fx.scratch("formats")
            for f in PhotoFormat.allCases {
                let u = dir.appendingPathComponent("c.\(f.ext)")
                try PhotoIO.write(PhotoFixture.coordinateImage(), to: u, format: f)
                try expect(PhotoIO.typeIdentifier(u) == f.uti, "\(f): type \(PhotoIO.typeIdentifier(u) ?? "nil")")
                let img = try PhotoIO.load(u)
                try expect(img.extent.size == PhotoFixture.size, "\(f): size \(img.extent.size)")
                let c = corners(img)
                try expect(cornersMatch(c, cropCorners(.full), tol: 0.01), "\(f): corners \(c.map(fmt))")
            }
            // RAW: a Linear DNG authored byte by byte, decoded by Core Image's RAW pipeline.
            let dng = dir.appendingPathComponent("c.dng")
            try DNGWriter.write(PhotoFixture.coordinateImage(width: 300, height: 200), to: dng)
            try expect(PhotoIO.typeIdentifier(dng) == "com.adobe.raw-image", "dng: type \(PhotoIO.typeIdentifier(dng) ?? "nil")")
            let px = Pixels(try PhotoIO.load(dng))
            try expect(px.width == 300 && px.height == 200, "dng: size \(px.width)x\(px.height)")
            let l = px.rgb(20, 100)[0], m = px.rgb(150, 100)[0], r = px.rgb(280, 100)[0]
            let t = px.rgb(150, 20)[1], b = px.rgb(150, 180)[1]
            try expect(l < m && m < r && t < b, "dng: gradients lost: red \(fmt([l, m, r])) green \(fmt([t, b]))")
        },
        Check(name: "import.orientation", workflows: ["W05", "W21"]) {
            // Stored 1200x800, tagged "rotate 90 CW": must show as 800x1200 with the stored bottom-left at top-left.
            let src = try fx.orientedJPEG()
            let img = try PhotoIO.load(src)
            try expect(img.extent.size == CGSize(width: 800, height: 1200), "loaded size \(img.extent.size)")
            let want = [(0.0, 1.0), (0.0, 0.0), (1.0, 1.0), (1.0, 0.0)]
            try expect(cornersMatch(corners(img), want, tol: 0.01), "upright corners \(corners(img).map(fmt))")
            // An edited export bakes the rotation into pixels and must reset the tag, or viewers rotate twice.
            let out = try fx.scratch("orient").appendingPathComponent("o.jpg")
            var r = PhotoRecipe()
            r.exposure = 0.01
            try PhotoIO.export(src, recipe: r, preset: PhotoExportPreset(format: .jpeg, gamut: .srgb), to: out)
            let o = PhotoIO.properties(out)[kCGImagePropertyOrientation as String] as? Int ?? 1
            try expect(o == 1, "export kept orientation tag \(o)")
            let back = try PhotoIO.load(out)
            try expect(back.extent.size == CGSize(width: 800, height: 1200) && cornersMatch(corners(back), want, tol: 0.015),
                       "export pixels \(back.extent.size) \(corners(back).map(fmt))")
        },
        Check(name: "import.library", workflows: ["W01", "W03", "W04"]) {
            // Picker, Files, drag-and-drop and paste all land in Importer.importFiles.
            let dir = try fx.scratch("import")
            let photo = try fx.cameraJPEG(), clip = try fx.clip()
            let renamed = dir.appendingPathComponent("copy of camera.jpg")
            try FileManager.default.copyItem(at: photo, to: renamed)
            let assets = try Importer.importFiles([photo, clip, renamed], into: dir.appendingPathComponent("Originals"), existing: [])
            try expect(assets.count == 2, "same photo under two names must import once: got \(assets.map { $0.name })")
            let p = assets.first { $0.kind == .photo }, v = assets.first { $0.kind == .video }
            try expect(p?.pixelWidth == 1200 && p?.pixelHeight == 800, "photo size \(String(describing: p))")
            try expect(v?.pixelWidth == 640 && v?.pixelHeight == 360, "video size \(String(describing: v))")
            let again = try Importer.importFiles([photo], into: dir.appendingPathComponent("Originals"), existing: assets)
            try expect(again.isEmpty, "re-import of an existing asset created \(again.count)")
            let txt = dir.appendingPathComponent("notes.txt")
            try Data("x".utf8).write(to: txt)
            do {
                _ = try Importer.importFiles([txt], into: dir, existing: [])
                throw CheckFailure("a .txt drop was accepted")
            } catch LibraryError.unsupported {}
        },
        Check(name: "import.live-photo", workflows: ["W06"]) {
            let lp = try fx.livePhoto()
            try expect(LivePhoto.stillID(lp.still) == Fixtures.liveID, "still ID \(LivePhoto.stillID(lp.still) ?? "nil")")
            try expect(LivePhoto.movieID(lp.movie) == Fixtures.liveID, "movie ID \(LivePhoto.movieID(lp.movie) ?? "nil")")
            let pairs = LivePhoto.pair(stills: [lp.still], movies: [lp.decoy, lp.movie])
            try expect(pairs.count == 1 && pairs[0].movie == lp.movie,
                       "paired with \(pairs.map { $0.movie.lastPathComponent }), want \(lp.movie.lastPathComponent)")
            let dir = try fx.scratch("live")
            let assets = try Importer.importFiles([lp.still, lp.movie], into: dir, existing: [])
            try expect(assets.count == 1 && assets[0].kind == .livePhoto && assets[0].pairedMovie != nil,
                       "import gave \(assets.map { "\($0.kind)" })")
        },
        Check(name: "access.limited", workflows: ["W02"]) {
            let a = (0..<5).map { Asset(id: "a\($0)", name: "\($0)", kind: .photo, file: "", pairedMovie: nil, pixelWidth: 1, pixelHeight: 1,
                                        photo: nil, video: nil, cloudETag: nil, reviewStatus: nil) }
            let limited = LibraryAccess.limited(["a1", "a3"])
            try expect(limited.visible(a).map { $0.id } == ["a1", "a3"], "limited shows \(limited.visible(a).map { $0.id })")
            try expect(limited.banner == "Limited Access", "banner \(limited.banner ?? "nil")")
            try expect(LibraryAccess.full.visible(a).count == 5 && LibraryAccess.full.banner == nil, "full access")
            try expect(LibraryAccess.notDetermined.visible(a).isEmpty, "notDetermined must show nothing before the prompt")
        },
        Check(name: "access.revoked", workflows: ["W38"]) {
            // Revoked in Settings mid-session: nothing shows, but the user's edits and sync queue survive.
            let dir = try fx.scratch("revoke")
            var lib = LibraryFile()
            var r = PhotoRecipe()
            r.exposure = 0.7
            lib.assets = [Asset(id: "x1", name: "x", kind: .photo, file: "x.jpg", pairedMovie: nil, pixelWidth: 1, pixelHeight: 1,
                                photo: r, video: nil, cloudETag: nil, reviewStatus: nil)]
            lib.pending = [PendingOp(assetID: "x1", kind: .recipe)]
            try LibraryStore.save(lib, to: dir.appendingPathComponent("library.json"))
            try expect(LibraryAccess.denied.visible(lib.assets).isEmpty, "denied still shows assets")
            try expect(LibraryAccess.denied.banner == "No Photos Access", "denied banner")
            let back = try LibraryStore.load(dir.appendingPathComponent("library.json"))
            try expect(back == lib, "library changed while access was revoked")
        },
    ]

    // MARK: photo edits

    static let editChecks: [Check] = [
        Check(name: "edit.exposure", workflows: ["W07"]) {
            let chart = try PhotoIO.load(try fx.chartPNG())
            var r = PhotoRecipe()
            r.exposure = 1
            let before = patch(chart, .gray18)[1], after = patch(Renderer.render(chart, r), .gray18)[1]
            try expect(near(after / before, 2, 0.06), "+1 EV must double linear light: \(before) -> \(after) (x\(after / before))")
        },
        Check(name: "edit.color-controls", workflows: ["W07"]) {
            let chart = try PhotoIO.load(try fx.chartPNG())
            var r = PhotoRecipe()
            r.saturation = 0
            let red = patch(Renderer.render(chart, r), .red)
            try expect(near(red[0], red[1], 0.01) && near(red[1], red[2], 0.01), "saturation 0 left colour \(fmt(red))")
            r = PhotoRecipe()
            r.contrast = 1.5
            let spread0 = patch(chart, .light)[1] - patch(chart, .dark)[1]
            let spread1 = patch(Renderer.render(chart, r), .light)[1] - patch(Renderer.render(chart, r), .dark)[1]
            try expect(spread1 > spread0 * 1.15, "contrast 1.5 spread \(spread0) -> \(spread1)")
            for (w, warmer) in [(1.0, true), (-1.0, false)] {
                r = PhotoRecipe()
                r.warmth = w
                let g = patch(Renderer.render(chart, r), .gray50)
                try expect(warmer ? g[0] > g[2] * 1.1 : g[2] > g[0] * 1.1, "warmth \(w) gave \(fmt(g))")
            }
        },
        Check(name: "edit.crop-from-proxy", workflows: ["W08"]) {
            // The crop is drawn on a half-size preview; it must mean the same region at full size.
            let full = CIImage(cgImage: PhotoFixture.coordinateImage())
            let proxySize = CGSize(width: 600, height: 400)
            var r = PhotoRecipe()
            r.crop = NormalizedRect.from(pixelRect: CGRect(x: 150, y: 100, width: 300, height: 200), shownSize: proxySize, fullSize: PhotoFixture.size)
            let out = Renderer.render(full, r)
            try expect(out.extent.size == CGSize(width: 600, height: 400), "full-res crop size \(out.extent.size)")
            let want = cropCorners(NormalizedRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5))
            try expect(cornersMatch(corners(out), want, tol: 0.01), "crop shows \(corners(out).map(fmt)), want \(want.map(fmt))")
        },
        Check(name: "edit.rotate-straighten-aspect", workflows: ["W08"]) {
            let full = CIImage(cgImage: PhotoFixture.coordinateImage())
            var r = PhotoRecipe()
            r.quarterTurns = 1
            let turned = Renderer.render(full, r)
            try expect(turned.extent.size == CGSize(width: 800, height: 1200), "turn size \(turned.extent.size)")
            try expect(cornersMatch(corners(turned), [(0, 1), (0, 0), (1, 1), (1, 0)], tol: 0.01), "turn corners \(corners(turned).map(fmt))")
            r = PhotoRecipe()
            r.straighten = 5
            let s = Pixels(Renderer.render(full, r))
            try expect(s.width == 1200 && s.height == 800, "straighten changed size \(s.width)x\(s.height)")
            let mid = s.sourcePosition(600, 400)
            try expect(near(mid.0, 0.5, 0.01) && near(mid.1, 0.5, 0.01), "straighten moved the centre to \(fmt(mid))")
            for (x, y) in [(2, 2), (1197, 2), (2, 797), (1197, 797)] {
                let c = s.rgb(x, y, r: 1)
                try expect(c[2] > 0.45 && (0.0...1.0).contains(c[0]) && (0.0...1.0).contains(c[1]), "empty corner at \(x),\(y): \(fmt(c))")
            }
            let tl = s.sourcePosition(2, 2), tr = s.sourcePosition(1197, 2)
            try expect(tr.1 < tl.1 - 0.05, "5 degrees did not tilt the top edge: \(fmt(tl)) \(fmt(tr))")
            r = PhotoRecipe()
            r.crop = NormalizedRect.aspect(1, in: PhotoFixture.size)
            let sq = Renderer.render(full, r)
            try expect(sq.extent.width == sq.extent.height && sq.extent.width == 800, "square preset \(sq.extent.size)")
        },
        Check(name: "edit.filters-lut", workflows: ["W09"]) {
            let chart = try PhotoIO.load(try fx.chartPNG())
            var r = PhotoRecipe()
            r.filter = .mono
            let m = patch(Renderer.render(chart, r), .red)
            try expect(near(m[0], m[1], 0.01) && near(m[1], m[2], 0.01), "mono left colour \(fmt(m))")
            r.filter = .sepia
            let s = patch(Renderer.render(chart, r), .gray50)
            try expect(s[0] > s[1] && s[1] > s[2], "sepia gray \(fmt(s))")
            r.filter = .swapLUT
            let red = patch(chart, .red, PhotoFixture.srgb), swapped = patch(Renderer.render(chart, r), .red, PhotoFixture.srgb)
            try expect(near(swapped[0], red[2], 0.02) && near(swapped[2], red[0], 0.02), "LUT red \(fmt(red)) -> \(fmt(swapped))")
        },
        Check(name: "edit.undo-redo", workflows: ["W10"]) {
            let h = EditHistory(PhotoRecipe(), original: PhotoRecipe())
            h.beginGesture()
            for i in 1...10 {
                var r = h.current
                r.exposure = Double(i) / 10
                h.update(r)
            }
            h.endGesture()
            var r = h.current
            r.filter = .mono
            h.apply(r)
            try expect(h.undoDepth == 2, "one drag + one filter must be 2 undo steps, got \(h.undoDepth)")
            h.undo()
            try expect(h.current.filter == .none && h.current.exposure == 1.0, "undo #1 -> \(h.current)")
            h.undo()
            try expect(h.current.isIdentity, "undo #2 must reach the original, got exposure \(h.current.exposure)")
            h.redo()
            try expect(h.current.exposure == 1.0 && h.canRedo, "redo -> exposure \(h.current.exposure)")
            // Compare (press and hold): showing the original never touches the edit.
            let shown = h.original
            try expect(shown.isIdentity && h.current.exposure == 1.0, "compare changed the edit")
        },
        Check(name: "edit.revert", workflows: ["W11"]) {
            let img = CIImage(cgImage: PhotoFixture.coordinateImage(width: 300, height: 200))
            let h = EditHistory(PhotoRecipe(), original: PhotoRecipe())
            var r = PhotoRecipe()
            r.exposure = 0.5; r.filter = .sepia; r.quarterTurns = 1; r.crop = NormalizedRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
            h.apply(r)
            h.revert()
            let a = Pixels(Renderer.render(img, h.current)), b = Pixels(img)
            try expect(a.width == b.width && a.data == b.data, "revert render differs from the untouched original")
            h.undo()
            try expect(h.current == r, "revert must be undoable")
        },
        Check(name: "edit.paste-batch", workflows: ["W12"]) {
            var source = PhotoRecipe()
            source.exposure = 0.4; source.warmth = 0.3; source.filter = .mono; source.crop = NormalizedRect(x: 0.2, y: 0, w: 0.5, h: 1)
            var targets = [PhotoRecipe(), PhotoRecipe(), PhotoRecipe()]
            targets[1].crop = NormalizedRect(x: 0, y: 0, w: 1, h: 0.5)
            targets[2].quarterTurns = 1
            let pasted = targets.map { source.pasted(onto: $0) }
            for (t, p) in zip(targets, pasted) {
                try expect(p.exposure == 0.4 && p.warmth == 0.3 && p.filter == .mono, "colour not pasted: \(p)")
                try expect(p.crop == t.crop && p.quarterTurns == t.quarterTurns, "paste overwrote geometry: \(p.crop) vs \(t.crop)")
            }
        },
    ]

    // MARK: video

    static func preview(_ r: VideoRecipe) throws -> DecodedVideo { try VideoDecoder.preview(VideoEditor.build(r, source: try fx.clip())) }

    static let videoChecks: [Check] = [
        Check(name: "video.trim", workflows: ["W13"]) {
            let r = VideoRecipe(segments: [ClipSegment(30, 120)])
            let d = try preview(r)
            let got = d.conformed(d.frames.count)
            try expect(d.frames.count == 90, "trim 30..<120 must be 90 frames, got \(d.frames.count)")
            try expect(got.first == 30 && got.last == 119, "first/last frame \(String(describing: got.first)) / \(String(describing: got.last))")
        },
        Check(name: "video.split-reorder-speed", workflows: ["W14"]) {
            let r = VideoRecipe(segments: [ClipSegment(200, 260), ClipSegment(30, 60, speed: (2, 1)), ClipSegment(100, 110, speed: (1, 2))])
            let d = try preview(r)
            let got = d.conformed(r.outputFrames).map { $0 ?? -1 }
            let want = r.expectedSourceFrames()
            let firstBad = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }
            try expect(firstBad == nil, "output frame \(firstBad?.offset ?? -1): shows \(firstBad?.element.0 ?? -1), want \(firstBad?.element.1 ?? -1)")
        },
        Check(name: "video.audio", workflows: ["W15"]) {
            var r = VideoRecipe(segments: [ClipSegment(30, 120)])
            let full = try preview(r)
            // Clicks at source 35, 45, ... land at output (f - 30) frames, to the sample.
            let want = VideoFixture.clickFrames(120).filter { $0 >= 30 }.map { Clock.sample(frame: $0 - 30) }
            let got = VideoDecoder.onsets(full.audio)
            try expect(got.count == want.count && zip(got, want).allSatisfy { abs($0 - $1) <= 2 }, "A/V sync: clicks at \(got), want \(want)")
            r.volume = 0.5
            let half = try preview(r).peak
            try expect(near(Double(half / full.peak), 0.5, 0.03), "volume 0.5: peak \(full.peak) -> \(half)")
            r.muted = true
            let muted = try preview(r).peak
            try expect(muted < 0.001, "muted peak \(muted)")
        },
        Check(name: "video.filter-every-frame", workflows: ["W16"]) {
            var r = VideoRecipe(segments: [ClipSegment(0, 60), ClipSegment(150, 180)])
            r.filter = .mono
            let d = try preview(r)
            let colored = d.frames.indices.filter { !d.frames[$0].neutral }
            try expect(colored.isEmpty, "\(colored.count) frames escaped the filter, first at \(colored.first ?? -1)")
            try expect(d.frames.allSatisfy { $0.id != nil }, "filter broke frame codes")
        },
        Check(name: "video.title", workflows: ["W17"]) {
            var r = VideoRecipe(segments: [ClipSegment(0, 90)])
            r.title = TitleCard(text: "Day 1", outputIn: 10, outputOut: 40)
            let d = try preview(r)
            let shown = d.frames.indices.filter { d.frames[$0].titleVisible }
            try expect(shown == Array(10..<40), "title on frames \(shown.first ?? -1)...\(shown.last ?? -1) (\(shown.count)), want 10..<40")
        },
    ]

    // MARK: colour + metadata

    static let colorChecks: [Check] = [
        Check(name: "color.p3-gamut", workflows: ["W18"]) {
            let dir = try fx.scratch("gamut")
            let p3 = dir.appendingPathComponent("p3.png")
            try PhotoIO.export(try fx.chartPNG(), recipe: PhotoRecipe(), preset: PhotoExportPreset(format: .png, gamut: .displayP3), to: p3)
            let g = patch(try PhotoIO.load(p3), .p3Green, PhotoFixture.p3)
            try expect(g[0] < 0.03 && g[1] > 0.97 && g[2] < 0.03, "P3 export lost wide-gamut green: \(fmt(g)) in P3")
            let srgb = dir.appendingPathComponent("s.jpg")
            try PhotoIO.export(try fx.chartPNG(), recipe: PhotoRecipe(), preset: PhotoExportPreset(format: .jpeg, gamut: .srgb), to: srgb)
            let model = PhotoIO.properties(srgb)[kCGImagePropertyProfileName as String] as? String ?? ""
            try expect(model.contains("sRGB"), "sRGB export profile is '\(model)'")
        },
        Check(name: "color.hdr", workflows: ["W19"]) {
            let dir = try fx.scratch("hdr")
            let keep = dir.appendingPathComponent("keep.tiff")
            try PhotoIO.export(try fx.hdrTIFF(), recipe: PhotoRecipe(), preset: PhotoExportPreset(format: .tiff, range: .preserveHDR), to: keep)
            let k = Pixels(try PhotoIO.load(keep), space: PhotoFixture.linearSRGB)
            let kept = (0..<4).map { k.rgb($0 * 100 + 50, 50)[1] }
            try expect(zip(kept, PhotoFixture.hdrLevels).allSatisfy { near($0, Double($1), Double($1) * 0.03) }, "HDR levels \(fmt(kept))")
            let sdr = dir.appendingPathComponent("sdr.jpg")
            try PhotoIO.export(try fx.hdrTIFF(), recipe: PhotoRecipe(), preset: PhotoExportPreset(format: .jpeg, gamut: .srgb), to: sdr)
            let s = Pixels(try PhotoIO.load(sdr))
            let mapped = (0..<4).map { s.rgb($0 * 100 + 50, 50)[1] }
            let distinct = zip(mapped, mapped.dropFirst()).allSatisfy { $1 - $0 > 0.04 }
            try expect(distinct && mapped.allSatisfy { $0 <= 1.0 }, "SDR tone map must keep highlights apart: \(fmt(mapped))")
        },
        Check(name: "metadata.exif-gps", workflows: ["W20"]) {
            let dir = try fx.scratch("meta")
            for remove in [false, true] {
                var r = PhotoRecipe()
                r.removeLocation = remove
                let out = dir.appendingPathComponent("m\(remove).jpg")
                try PhotoIO.export(try fx.cameraJPEG(), recipe: r, preset: PhotoExportPreset(format: .jpeg, gamut: .srgb), to: out)
                let p = PhotoIO.properties(out)
                let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                try expect(exif[kCGImagePropertyExifLensModel as String] as? String == "ProofSheet Fixture 26mm f/1.6", "lens lost (remove=\(remove))")
                try expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:11:18 09:41:00", "capture date lost")
                let hasGPS = p[kCGImagePropertyGPSDictionary as String] != nil
                try expect(hasGPS == !remove, remove ? "Remove Location left GPS in the file" : "GPS dropped without being asked")
            }
        },
    ]

    // MARK: export

    static let exportChecks: [Check] = [
        Check(name: "export.photo-presets", workflows: ["W21"]) {
            let dir = try fx.scratch("presets")
            var r = PhotoRecipe()
            r.crop = NormalizedRect(x: 0, y: 0, w: 0.5, h: 1)
            for (name, preset) in PhotoExportPreset.standard.sorted(by: { $0.key < $1.key }) where preset.range == .sdr {
                let out = dir.appendingPathComponent("\(name).\(preset.format.ext)")
                try PhotoIO.export(try fx.coordinate16TIFF(), recipe: r, preset: preset, to: out)
                try expect(PhotoIO.typeIdentifier(out) == preset.format.uti, "\(name): wrote \(PhotoIO.typeIdentifier(out) ?? "nil")")
                let img = try PhotoIO.load(out)
                let longest = max(img.extent.width, img.extent.height)
                try expect(longest == CGFloat(min(preset.maxDimension ?? 800, 800)), "\(name): size \(img.extent.size)")
                try expect(cornersMatch(corners(img), cropCorners(r.crop), tol: 0.015), "\(name): corners \(corners(img).map(fmt))")
            }
        },
        Check(name: "export.video-presets", workflows: ["W21"]) {
            var r = VideoRecipe(segments: [ClipSegment(30, 120)])
            r.title = TitleCard(text: "Proof", outputIn: 0, outputOut: 15)
            let b = try VideoEditor.build(r, source: try fx.clip())
            let dir = try fx.scratch("vpresets")
            for p in VideoExportPreset.all {
                let out = dir.appendingPathComponent("\(p.codec).mov")
                try VideoExport.export(b, preset: p, to: out)
                try expect(VideoDecoder.codec(out) == p.codec, "\(p.name): codec \(VideoDecoder.codec(out) ?? "nil")")
                let d = try VideoDecoder.file(out)
                try expect(d.frames.count == 90, "\(p.name): \(d.frames.count) frames")
                let wrong = d.ids.enumerated().filter { $0.element != nil && $0.element != 30 + $0.offset }
                let readable = d.ids.compactMap { $0 }.count
                try expect(wrong.isEmpty && readable >= 81, "\(p.name): \(wrong.count) frames out of place, \(readable)/90 readable")
                try expect(d.frames.prefix(15).allSatisfy { $0.titleVisible } && !d.frames[15].titleVisible, "\(p.name): title timing")
            }
        },
        Check(name: "export.cancel-and-disk", workflows: ["W23"]) {
            let dir = try fx.scratch("cancel")
            let b = try VideoEditor.build(VideoRecipe(segments: [ClipSegment(0, 300)]), source: try fx.clip())
            let out = dir.appendingPathComponent("c.mov")
            do {
                try VideoExport.run(try VideoExport.session(b, preset: VideoExportPreset.all[0], to: out), cancelAtProgress: 0.05)
                throw CheckFailure("export finished before cancel took effect")
            } catch VideoError.cancelled {}
            try expect(!FileManager.default.fileExists(atPath: out.path), "cancelled export left a partial file")
            for attempt in ["photo", "video"] {
                let target = dir.appendingPathComponent("full-\(attempt)")
                do {
                    if attempt == "photo" {
                        try PhotoIO.export(try fx.cameraJPEG(), recipe: PhotoRecipe(), preset: PhotoExportPreset(format: .heic), to: target, disk: .fixed(10_000))
                    } else {
                        try VideoExport.export(b, preset: VideoExportPreset.all[0], to: target, disk: .fixed(10_000))
                    }
                    throw CheckFailure("\(attempt) export ran with 10 KB free")
                } catch PhotoIOError.insufficientSpace {}
                try expect(!FileManager.default.fileExists(atPath: target.path), "\(attempt): full disk still wrote a file")
            }
        },
    ]

    // MARK: cloud

    static func uploaded(_ c: SyncClient, file: URL, kind: AssetKind = .photo) throws -> String {
        let id = try Importer.contentID(file)
        try c.upload(file, id: id, name: file.lastPathComponent, kind: kind)
        return id
    }

    static let syncChecks: [Check] = [
        Check(name: "sync.resumable-upload", workflows: ["W24"]) {
            try server.admin("reset")
            let file = try fx.coordinate16TIFF()
            let size = try Data(contentsOf: file).count
            let c = try client("iphone")
            let id = try Importer.contentID(file)
            do {
                try c.upload(file, id: id, name: "coord.tiff", kind: .photo, chunkSize: 256 * 1024, interruptAfter: 4)
                throw CheckFailure("interrupt did not happen")
            } catch is SyncClient.UploadInterrupted {}
            try c.upload(file, id: id, name: "coord.tiff", kind: .photo, chunkSize: 256 * 1024)
            try expect(c.bytesSent == size, "resume re-sent data: \(c.bytesSent) bytes for a \(size)-byte file")
            try expect(try c.original(id) == (try Data(contentsOf: file)), "server copy differs from the original")
        },
        Check(name: "sync.cross-device", workflows: ["W25"]) {
            try server.admin("reset")
            let file = try fx.coordinate16TIFF()
            let phone = try client("iphone"), mac = try client("mac")
            let id = try uploaded(phone, file: file)
            // iPhone edits on a half-size proxy.
            var r = PhotoRecipe()
            r.exposure = 0.3
            r.crop = NormalizedRect.from(pixelRect: CGRect(x: 60, y: 40, width: 300, height: 200), shownSize: CGSize(width: 600, height: 400),
                                         fullSize: PhotoFixture.size)
            try phone.putRecipe(id, r, ifMatch: try phone.recipe(id).etag)
            // Mac pulls original + recipe and renders full size.
            let remote = try mac.recipe(id)
            let dir = try fx.scratch("xdev")
            let local = dir.appendingPathComponent("orig.tiff")
            try mac.original(id).write(to: local)
            guard let rr = remote.recipe else { throw CheckFailure("mac got no recipe") }
            let macRender = Renderer.render(try PhotoIO.load(local), rr)
            let want = cropCorners(NormalizedRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5))
            var neutral = rr
            neutral.exposure = 0
            let geometry = corners(Renderer.render(try PhotoIO.load(local), neutral))
            try expect(cornersMatch(geometry, want, tol: 0.01), "mac shows \(geometry.map(fmt)), iPhone framed \(want.map(fmt))")
            let phoneFull = Pixels(Renderer.render(try PhotoIO.load(file), r)), macPx = Pixels(macRender)
            try expect(phoneFull.width == macPx.width && phoneFull.height == macPx.height, "sizes differ")
            let diff = stride(from: 0, to: macPx.data.count, by: 997).map { abs(macPx.data[$0] - phoneFull.data[$0]) }.max() ?? 0
            try expect(diff < 0.002, "renders differ across devices by \(diff)")
        },
        Check(name: "sync.offline-queue", workflows: ["W26"]) {
            try server.admin("reset")
            let online = try client("iphone")
            let id = try uploaded(online, file: try fx.cameraJPEG())
            let base = try online.recipe(id).etag
            let dead = SyncClient(base: URL(string: "http://127.0.0.1:9")!, device: "iphone")
            var q = OfflineQueue()
            for ev in [0.1, 0.2, 0.3] {
                var r = PhotoRecipe()
                r.exposure = ev
                do {
                    try dead.putRecipe(id, r, ifMatch: base)
                    throw CheckFailure("put succeeded with no network")
                } catch SyncError.offline {
                    q.enqueue(id, r, base: base)
                }
            }
            try expect(q.entries.count == 1, "3 offline edits to one photo must coalesce, got \(q.entries.count)")
            let file = try fx.scratch("queue").appendingPathComponent("queue.json")
            try q.save(to: file)
            var restored = OfflineQueue.load(file)
            try expect(restored == q, "queue did not survive relaunch")
            let report = try restored.flush(online)
            try expect(report.pushed == [id] && restored.entries.isEmpty, "flush report \(report)")
            try expect(try online.recipe(id).recipe?.exposure == 0.3, "server has \(String(describing: try online.recipe(id).recipe?.exposure))")
        },
        Check(name: "sync.conflict-keep-both", workflows: ["W27"]) {
            try server.admin("reset")
            let mac = try client("mac"), phone = try client("iphone")
            let id = try uploaded(mac, file: try fx.cameraJPEG())
            let base = try phone.recipe(id).etag
            var phoneEdit = PhotoRecipe()
            phoneEdit.filter = .mono
            var q = OfflineQueue()
            q.enqueue(id, phoneEdit, base: base)          // iPhone edits on a plane
            var macEdit = PhotoRecipe()
            macEdit.exposure = 1
            try mac.putRecipe(id, macEdit, ifMatch: base)  // Mac edits meanwhile
            let report = try q.flush(phone)
            try expect(report.conflicts == [id] && report.copies.count == 1, "conflict not detected: \(report)")
            try expect(try mac.recipe(id).recipe == macEdit, "Mac's edit was overwritten")
            try expect(try mac.recipe(report.copies[0]).recipe == phoneEdit, "iPhone's edit was not kept as a copy")
        },
        Check(name: "sync.delete-restore", workflows: ["W28"]) {
            try server.admin("reset")
            let mac = try client("mac"), phone = try client("iphone")
            let id = try uploaded(mac, file: try fx.cameraJPEG())
            try mac.delete(id)
            try expect(try phone.list().isEmpty && (try phone.list(deleted: true)) == [id], "iPhone sees \(try phone.list()) / deleted \(try phone.list(deleted: true))")
            try phone.restore(id)
            try expect(try mac.list() == [id] && (try mac.list(deleted: true)).isEmpty, "restore not visible on Mac")
        },
        Check(name: "sync.quota-auth-retry", workflows: ["W29"]) {
            try server.admin("reset")
            try server.admin("config", ["quota": 1000])
            let c = try client("iphone")
            do {
                _ = try uploaded(c, file: try fx.cameraJPEG())
                throw CheckFailure("upload past quota succeeded")
            } catch SyncError.quotaExceeded {}
            try expect(try c.list().isEmpty, "a rejected upload left an asset")
            try server.admin("config", ["quota": 512 * 1024 * 1024, "token_ttl": 0.2])
            let id = try uploaded(c, file: try fx.cameraJPEG())
            Thread.sleep(forTimeInterval: 0.3)
            try expect(try c.list() == [id], "expired token was not refreshed")
            try server.admin("config", ["flaky": 2, "token_ttl": 3600])
            let before = c.retries
            try expect(try c.list() == [id], "list failed under two 503s")
            try expect(c.retries - before == 2, "expected 2 retries, saw \(c.retries - before)")
        },
        Check(name: "sync.versions", workflows: ["W30"]) {
            try server.admin("reset")
            let c = try client("mac")
            let id = try uploaded(c, file: try fx.cameraJPEG())
            var tag = try c.recipe(id).etag
            for ev in [0.5, 1.0, 1.5] {
                var r = PhotoRecipe()
                r.exposure = ev
                tag = try c.putRecipe(id, r, ifMatch: tag)
            }
            try expect(try c.versions(id).map { $0.version } == [0, 1, 2, 3], "versions \(try c.versions(id).map { $0.version })")
            try c.restoreVersion(id, 1)
            try expect(try c.recipe(id).recipe?.exposure == 0.5, "restore v1 gave \(String(describing: try c.recipe(id).recipe?.exposure))")
        },
        Check(name: "share.comments-status", workflows: ["W32", "W33"]) {
            try server.admin("reset")
            let c = try client("mac")
            let id = try uploaded(c, file: try fx.cameraJPEG())
            let tok = try c.share(id)
            var (s, _) = try server.browser("POST", "/s/\(tok)/comments", json: ["text": "sky", "x": 0.25, "y": 0.1])
            try expect(s == 201, "comment -> \(s)")
            let (_, list) = try server.browser("GET", "/s/\(tok)/comments")
            let rows = try JSONSerialization.jsonObject(with: list) as? [[String: Any]] ?? []
            try expect(rows.count == 1 && rows[0]["x"] as? Double == 0.25, "comments \(rows)")
            (s, _) = try server.browser("POST", "/s/\(tok)/status", json: ["status": "approved"])
            try expect(s == 200, "approve -> \(s)")
            try expect(try c.recipe(id).review == "approved", "app sees review \(try c.recipe(id).review)")
        },
        Check(name: "share.revoke-expiry-password", workflows: ["W34"]) {
            try server.admin("reset")
            let c = try client("mac")
            let id = try uploaded(c, file: try fx.cameraJPEG())
            let tok = try c.share(id)
            try expect(try server.browser("GET", "/s/\(tok)").0 == 200, "fresh link")
            try c.revoke(tok)
            try expect(try server.browser("GET", "/s/\(tok)").0 == 404, "revoked link still serves (\(try server.browser("GET", "/s/\(tok)").0))")
            try expect(try server.browser("GET", "/s/\(tok)/media").0 == 404, "revoked media still serves")
            let short = try c.share(id, expiresIn: 0.2)
            Thread.sleep(forTimeInterval: 0.3)
            try expect(try server.browser("GET", "/s/\(short)").0 == 410, "expired link -> \(try server.browser("GET", "/s/\(short)").0)")
            let locked = try c.share(id, password: "darkroom")
            try expect(try server.browser("GET", "/s/\(locked)/media").0 == 401, "password link served media without a password")
        },
        Check(name: "share.downloads", workflows: ["W35"]) {
            try server.admin("reset")
            let c = try client("mac")
            let file = try fx.cameraJPEG()
            let id = try uploaded(c, file: file)
            let dir = try fx.scratch("rendition")
            let edited = dir.appendingPathComponent("e.jpg")
            var r = PhotoRecipe()
            r.filter = .mono
            try PhotoIO.export(file, recipe: r, preset: PhotoExportPreset(format: .jpeg, gamut: .srgb), to: edited)
            try c.putRendition(id, data: try Data(contentsOf: edited))
            let tok = try c.share(id)
            let o = try server.browser("GET", "/s/\(tok)/media?variant=original&download=1").1
            let e = try server.browser("GET", "/s/\(tok)/media?variant=edited&download=1").1
            try expect(sha(o) == sha(try Data(contentsOf: file)), "original download is not byte-identical")
            try expect(sha(e) == sha(try Data(contentsOf: edited)), "edited download is not the rendition")
        },
    ]

    // MARK: platform

    static let platformChecks: [Check] = [
        Check(name: "continuity.handoff-deeplink", workflows: ["W36"]) {
            var r = PhotoRecipe()
            r.exposure = 0.25; r.crop = NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4)
            let info = try Continuity.userInfo(assetID: "abc123", recipe: r)
            guard let back = Continuity.decode(info) else { throw CheckFailure("Handoff payload did not decode") }
            try expect(back.assetID == "abc123" && back.recipe == r, "Handoff changed the edit")
            try expect(Continuity.assetID(from: Continuity.url(assetID: "abc123")) == "abc123", "deep link round trip")
            for bad in ["proofsheet://asset/", "proofsheet://album/abc", "https://asset/abc", "proofsheet://asset/..%2F..%2Fetc"] {
                try expect(Continuity.assetID(from: URL(string: bad)!) == nil, "accepted bad link \(bad)")
            }
        },
        Check(name: "library.autosave", workflows: ["W37"]) {
            let dir = try fx.scratch("autosave")
            var lib = LibraryFile()
            var r = PhotoRecipe()
            r.exposure = 0.6; r.filter = .sepia
            var v = VideoRecipe(segments: [ClipSegment(10, 50)])
            v.title = TitleCard(text: "Hi", outputIn: 0, outputOut: 10)
            lib.assets = [
                Asset(id: "p", name: "p", kind: .photo, file: "p.jpg", pairedMovie: nil, pixelWidth: 4, pixelHeight: 3, photo: r, video: nil,
                      cloudETag: "\"v2\"", reviewStatus: "approved"),
                Asset(id: "v", name: "v", kind: .video, file: "v.mov", pairedMovie: nil, pixelWidth: 640, pixelHeight: 360, photo: nil, video: v,
                      cloudETag: nil, reviewStatus: nil),
            ]
            lib.pending = [PendingOp(assetID: "p", kind: .recipe)]
            let url = dir.appendingPathComponent("library.json")
            try LibraryStore.save(lib, to: url)
            try expect(try LibraryStore.load(url) == lib, "relaunch lost state")
        },
        Check(name: "library.migration", workflows: ["W44", "W45"]) {
            let dir = try fx.scratch("migrate")
            let v1 = """
            {"version":1,"items":[{"id":"old1","name":"IMG_0001.JPG","file":"old1.jpg","width":4000,"height":3000,"ev":0.5,"crop":[1000,750,2000,1500]},
            {"id":"old2","name":"IMG_0002.JPG","file":"old2.jpg","width":3000,"height":4000}],"queue":["old1"]}
            """
            let url = dir.appendingPathComponent("library.json")
            try Data(v1.utf8).write(to: url)
            let lib = try LibraryStore.load(url)
            try expect(lib.schema == 2 && lib.assets.count == 2, "migrated \(lib.assets.count) assets, schema \(lib.schema)")
            let a = lib.assets[0].photo!
            try expect(a.exposure == 0.5 && a.crop == NormalizedRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), "v1 edit became \(a)")
            try expect(lib.assets[1].photo!.crop == .full, "uncropped v1 asset gained a crop")
            try expect(lib.pending == [PendingOp(assetID: "old1", kind: .recipe)], "upgrade lost unsynced edits: \(lib.pending)")
            try LibraryStore.save(lib, to: url)
            try expect(try LibraryStore.load(url) == lib, "v2 file does not round-trip")
        },
        Check(name: "perf.budgets", workflows: ["W43"]) {
            func time(_ f: () throws -> Void) rethrows -> Double { let t = Date(); try f(); return Date().timeIntervalSince(t) }
            let src = try fx.coordinate16TIFF()
            let input = try PhotoIO.load(src)
            var r = PhotoRecipe()
            r.exposure = 0.3; r.filter = .sepia; r.straighten = 3
            _ = Pixels(Renderer.render(input, r, maxDimension: 600))  // warm up
            let proxy = try time { _ = Pixels(Renderer.render(input, r, maxDimension: 600)) }
            let dir = try fx.scratch("perf")
            let export = try time { try PhotoIO.export(src, recipe: r, preset: PhotoExportPreset(format: .heic), to: dir.appendingPathComponent("p.heic")) }
            let scrub = try time { _ = try preview(VideoRecipe(segments: [ClipSegment(0, 90)])) }
            let budgets = [("proxy render", proxy, 0.5), ("full HEIC export", export, 3.0), ("90-frame preview decode", scrub, 6.0)]
            print("    perf: " + budgets.map { String(format: "%@ %.0f ms (budget %.0f)", $0.0, $0.1 * 1000, $0.2 * 1000) }.joined(separator: ", "))
            for (name, got, budget) in budgets { try expect(got <= budget, String(format: "%@ took %.2f s, budget %.2f s", name, got, budget)) }
        },
    ]

    /// Fault -> the checks that must fail with it switched on (and no others).
    public static let expectedFailures: [Fault: Set<String>] = [
        .cropPixelsNotNormalized: ["edit.crop-from-proxy", "sync.cross-device"],
        .recipeAppliedTwice: ["edit.exposure"],
        .gpsNotStripped: ["metadata.exif-gps"],
        .p3ClampedToSRGB: ["color.p3-gamut"],
        .hdrClipped: ["color.hdr"],
        .trimIncludesOutFrame: ["video.trim", "video.split-reorder-speed", "export.video-presets"],
        .undoPerDragTick: ["edit.undo-redo"],
        .livePhotoIgnoresID: ["import.live-photo"],
        .migrationDropsPending: ["library.migration"],
        .noRetryOn503: ["sync.quota-auth-retry"],
        .uploadNotResumable: ["sync.resumable-upload"],
        .conflictSilentOverwrite: ["sync.conflict-keep-both"],
        .revokedLinkStillServes: ["share.revoke-expiry-password"],
    ]
}
