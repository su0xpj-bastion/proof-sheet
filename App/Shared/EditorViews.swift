import AVFoundation
import ProofKit
import SwiftUI

struct PhotoEditorView: View {
    @EnvironmentObject var model: AppModel
    let asset: Asset
    @State private var history: EditHistory<PhotoRecipe>
    @State private var recipe: PhotoRecipe
    @State private var dragging = false
    @State private var comparing = false
    @State private var preview: CGImage?
    @State private var showExport = false

    init(asset: Asset) {
        self.asset = asset
        let r = asset.photo ?? PhotoRecipe()
        _history = State(initialValue: EditHistory(r, original: PhotoRecipe()))
        _recipe = State(initialValue: r)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if let p = preview {
                        Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 360)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 240)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Preview"))
                .accessibilityIdentifier("preview")
                .accessibilityValue(comparing ? "original" : recipe.summary)

                Text(comparing ? "Original" : "Edited").font(.caption).accessibilityIdentifier("compareLabel")
                Text(recipe.summary).font(.system(.footnote, design: .monospaced)).accessibilityIdentifier("recipeSummary")

                Group {
                    slider("Exposure", \.exposure, -2...2, id: "exposureSlider")
                    slider("Contrast", \.contrast, 0.5...1.5, id: "contrastSlider")
                    slider("Saturation", \.saturation, 0...2, id: "saturationSlider")
                    slider("Warmth", \.warmth, -1...1, id: "warmthSlider")
                }

                Picker("Filter", selection: Binding(get: { recipe.filter }, set: { set(\.filter, $0) })) {
                    Text("None").tag(PhotoFilter.none)
                    Text("Mono").tag(PhotoFilter.mono)
                    Text("Sepia").tag(PhotoFilter.sepia)
                    Text("Swap").tag(PhotoFilter.swapLUT)
                }
                .pickerStyle(SegmentedPickerStyle())
                .accessibilityIdentifier("filterPicker")

                // A plain VStack, not HStack (long localizations push buttons off screen) and not LazyVGrid
                // (lazy cells below the fold do not exist yet, so VoiceOver and XCUITest cannot reach them).
                VStack(alignment: .leading, spacing: 8) {
                    Button("Rotate") { set(\.quarterTurns, recipe.quarterTurns + 1) }.accessibilityIdentifier("rotateButton")
                    Button("Square") { set(\.crop, NormalizedRect.aspect(1, in: CGSize(width: asset.pixelWidth, height: asset.pixelHeight))) }
                        .accessibilityIdentifier("aspectSquare")
                    Button("Original Crop") { set(\.crop, .full) }.accessibilityIdentifier("aspectOriginal")
                }
                Toggle("Remove Location", isOn: Binding(get: { recipe.removeLocation }, set: { set(\.removeLocation, $0) }))
                    .accessibilityIdentifier("removeLocationToggle")

                VStack(alignment: .leading, spacing: 8) {
                    Button("Undo") { history.undo(); sync() }.disabled(!history.canUndo).accessibilityIdentifier("undoButton")
                    Button("Redo") { history.redo(); sync() }.disabled(!history.canRedo).accessibilityIdentifier("redoButton")
                    Button("Revert") { history.revert(); sync() }.accessibilityIdentifier("revertButton")
                    Button(comparing ? "Show Edit" : "Compare") { comparing.toggle(); render() }.accessibilityIdentifier("compareButton")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Copy Edits") { model.clipboard = recipe }.accessibilityIdentifier("copyEditsButton")
                    Button("Export…") { showExport = true }.accessibilityIdentifier("exportButton")
                }
            }
            .padding()
        }
        .navigationTitle(Text(asset.name))
        .accessibilityIdentifier("editor.\(asset.name)")
        .onAppear(perform: render)
        .userActivity(Continuity.activityType) { activity in
            activity.title = asset.name
            activity.userInfo = (try? Continuity.userInfo(assetID: asset.id, recipe: recipe)) ?? [:]
            activity.isEligibleForHandoff = true
        }
        .sheet(isPresented: $showExport) {
            PhotoExportSheet(asset: asset, recipe: recipe, isPresented: $showExport).environmentObject(model)
        }
    }

    func slider(_ title: String, _ key: WritableKeyPath<PhotoRecipe, Double>, _ range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading) {
            Text(LocalizedStringKey(title)).font(.caption)
            Slider(value: Binding(get: { recipe[keyPath: key] }, set: { v in
                var r = recipe
                r[keyPath: key] = (v * 100).rounded() / 100
                // A drag is one undo step; a keyboard or VoiceOver increment (no drag) is its own step.
                if dragging { history.update(r) } else { history.apply(r) }
                sync()
            }), in: range, onEditingChanged: { editing in
                if editing { dragging = true; history.beginGesture() } else { history.endGesture(); dragging = false; sync() }
            })
            .accessibilityIdentifier(id)
            .accessibilityLabel(Text(LocalizedStringKey(title)))
        }
    }

    func set<V>(_ key: WritableKeyPath<PhotoRecipe, V>, _ v: V) {
        var r = recipe
        r[keyPath: key] = v
        history.apply(r)
        sync()
    }

    func sync() {
        recipe = history.current
        model.update(asset.id, photo: recipe)
        render()
    }

    func render() {
        let url = model.url(of: asset), r = comparing ? PhotoRecipe() : recipe
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Preview.image(url, r)
            DispatchQueue.main.async { preview = img }
        }
    }
}

/// Export progress, cancel, full disk, then share.
final class ExportJob: ObservableObject {
    enum State: Equatable { case idle, running(Double), done(URL), cancelled, failed(String) }
    @Published var state = State.idle
    private var cancelled = false
    private var session: AVAssetExportSession?

    func cancel() {
        cancelled = true
        session?.cancelExport()
    }

    /// `delay` stretches the job so a UI test can press Cancel mid-export.
    func run(delay: Double, _ work: @escaping (ExportJob) throws -> URL) {
        cancelled = false
        state = .running(0)
        DispatchQueue.global(qos: .userInitiated).async {
            let steps = max(1, Int(delay * 10))
            for i in 0..<steps where delay > 0 {
                if self.cancelled { break }
                Thread.sleep(forTimeInterval: 0.1)
                DispatchQueue.main.async { if case .running = self.state { self.state = .running(Double(i) / Double(steps)) } }
            }
            let result: State
            if self.cancelled {
                result = .cancelled
            } else {
                do { result = .done(try work(self)) } catch VideoError.cancelled { result = .cancelled } catch PhotoIOError.insufficientSpace {
                    result = .failed("Not enough storage to export")
                } catch { result = .failed("\(error)") }
            }
            DispatchQueue.main.async { self.state = result }
        }
    }

    func attach(_ s: AVAssetExportSession) { session = s }
}

struct ExportStatusView: View {
    @ObservedObject var job: ExportJob
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch job.state {
            case .idle:
                EmptyView()
            case .running(let p):
                ProgressView(value: p).accessibilityIdentifier("exportProgress")
                Button("Cancel Export") { job.cancel() }.accessibilityIdentifier("cancelExport")
            case .done(let url):
                Text("Exported \(url.lastPathComponent)").accessibilityIdentifier("exportResult")
                Button("Share…") { sharing = true }
                    .accessibilityIdentifier("shareButton")
                    .background(ShareSheet(items: [url], isPresented: $sharing))
            case .cancelled:
                Text("Export cancelled").accessibilityIdentifier("exportResult")
            case .failed(let why):
                Text(why).foregroundColor(.red).accessibilityIdentifier("exportError")
            }
        }
    }
}

struct PhotoExportSheet: View {
    @EnvironmentObject var model: AppModel
    let asset: Asset
    let recipe: PhotoRecipe
    @Binding var isPresented: Bool
    @State private var presetName = "JPEG sRGB"
    @StateObject private var job = ExportJob()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.title2).accessibilityAddTraits(.isHeader)
            Picker("Format", selection: $presetName) {
                ForEach(PhotoExportPreset.standard.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("presetPicker")
            Button("Export") { start() }.accessibilityIdentifier("startExport")
            ExportStatusView(job: job)
            Button("Done") { isPresented = false }.accessibilityIdentifier("exportDone")
        }
        .padding()
        .frame(minWidth: 360)
    }

    func start() {
        let preset = PhotoExportPreset.standard[presetName]!
        let src = model.url(of: asset)
        let base = (asset.name as NSString).deletingPathExtension
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(base)-edited.\(preset.format.ext)")
        let disk = model.options.diskFree.map { DiskBudget.fixed($0) } ?? .system
        let r = recipe
        job.run(delay: model.options.exportDelay) { _ in
            try PhotoIO.export(src, recipe: r, preset: preset, to: out, disk: disk)
            return out
        }
    }
}

struct VideoEditorView: View {
    @EnvironmentObject var model: AppModel
    let asset: Asset
    @State private var recipe: VideoRecipe
    @StateObject private var job = ExportJob()
    @State private var player: AVPlayer?

    init(asset: Asset) {
        self.asset = asset
        _recipe = State(initialValue: asset.video ?? VideoRecipe(segments: [ClipSegment(0, 120)]))
    }

    var seg: ClipSegment { recipe.segments[0] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Frames: \(recipe.outputFrames)").font(.headline).accessibilityIdentifier("frameCount")
                Stepper("In: \(seg.sourceIn)", onIncrement: { change(in: 10) }, onDecrement: { change(in: -10) })
                    .accessibilityIdentifier("trimIn")
                Stepper("Out: \(seg.sourceOut)", onIncrement: { change(out: 10) }, onDecrement: { change(out: -10) })
                    .accessibilityIdentifier("trimOut")
                Picker("Speed", selection: Binding(get: { seg.speedNum * 10 / seg.speedDen }, set: { v in
                    recipe.segments[0].speedNum = v == 20 ? 2 : 1
                    recipe.segments[0].speedDen = v == 5 ? 2 : 1
                    save()
                })) {
                    Text("0.5×").tag(5)
                    Text("1×").tag(10)
                    Text("2×").tag(20)
                }
                .pickerStyle(SegmentedPickerStyle())
                .accessibilityIdentifier("speedPicker")
                Toggle("Mute", isOn: Binding(get: { recipe.muted }, set: { recipe.muted = $0; save() }))
                    .accessibilityIdentifier("muteToggle")
                Picker("Filter", selection: Binding(get: { recipe.filter }, set: { recipe.filter = $0; save() })) {
                    Text("None").tag(PhotoFilter.none)
                    Text("Mono").tag(PhotoFilter.mono)
                }
                .pickerStyle(SegmentedPickerStyle())
                .accessibilityIdentifier("videoFilterPicker")
                Button("Export H.264") { export() }.accessibilityIdentifier("exportButton")
                ExportStatusView(job: job)
            }
            .padding()
        }
        .navigationTitle(Text(asset.name))
        .accessibilityIdentifier("editor.\(asset.name)")
    }

    func change(in d: Int = 0, out o: Int = 0) {
        let newIn = max(0, min(seg.sourceIn + d, seg.sourceOut - 10))
        let newOut = max(newIn + 10, min(seg.sourceOut + o, 120))
        recipe.segments[0].sourceIn = newIn
        recipe.segments[0].sourceOut = newOut
        save()
    }

    func save() { model.update(asset.id, video: recipe) }

    func export() {
        let src = model.url(of: asset), r = recipe
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\((asset.name as NSString).deletingPathExtension)-edited.mov")
        let disk = model.options.diskFree.map { DiskBudget.fixed($0) } ?? .system
        job.run(delay: model.options.exportDelay) { job in
            let s = try VideoExport.session(try VideoEditor.build(r, source: src), preset: VideoExportPreset.all[0], to: out, disk: disk)
            job.attach(s)
            try VideoExport.run(s)
            return out
        }
    }
}
