import ProofKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var showImport = false
    @State private var showSelectMore = false

    var body: some View {
        List {
            if let banner = model.access.banner {
                Section {
                    Text(LocalizedStringKey(banner)).font(.headline).accessibilityIdentifier("accessBanner")
                    if case .limited = model.access {
                        Button("Select More Photos") { showSelectMore = true }.accessibilityIdentifier("selectMore")
                    }
                }
            }
            if !model.library.pending.isEmpty {
                Text("Pending sync: \(model.library.pending.count)").font(.footnote).accessibilityIdentifier("pendingBadge")
            }
            ForEach(model.visibleAssets) { asset in
                NavigationLink(destination: EditorRouter(id: asset.id),
                               tag: asset.id, selection: $model.selection) {
                    AssetRow(asset: asset)
                }
                .accessibilityIdentifier("asset.\(asset.name)")
                .accessibilityLabel(Text(asset.spokenName))
                .accessibilityValue(asset.id)
            }
        }
        .navigationTitle(Text("Library"))
        .toolbar {
            ToolbarItem {
                Button { showImport = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("importButton")
            }
            ToolbarItem {
                Button { model.pasteEditsToAllOtherPhotos(except: model.selection) } label: { Label("Paste Edits", systemImage: "doc.on.clipboard") }
                    .disabled(model.clipboard == nil)
                    .accessibilityIdentifier("pasteEdits")
            }
            ToolbarItem {
                // Stands in for the user turning Photos access off in Settings while the app runs (UI tests only).
                if model.options.uiTest {
                    Button { model.revokeAccess() } label: { Label("Revoke Access", systemImage: "lock.slash") }
                        .accessibilityIdentifier("simulateRevoke")
                }
            }
        }
        .sheet(isPresented: $showImport) { ImportSheet(isPresented: $showImport).environmentObject(model) }
        .sheet(isPresented: $showSelectMore) { SelectMoreSheet(isPresented: $showSelectMore).environmentObject(model) }
        .alert(isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Alert(title: Text(model.lastError ?? ""))
        }
        .modifier(FileDropAndPaste(load: loadURLs))
    }

    func loadURLs(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { DispatchQueue.main.async { model.importFiles([u]) } }
            }
        }
    }
}

/// macOS: paste file URLs (Cmd-V) or drop them from Finder. iOS: files arrive via the importer.
struct FileDropAndPaste: ViewModifier {
    let load: ([NSItemProvider]) -> Void
    func body(content: Content) -> some View {
        #if os(macOS)
        return content
            .onPasteCommand(of: [UTType.fileURL]) { load($0) }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { load($0); return true }
        #else
        return content.onDrop(of: [UTType.fileURL], isTargeted: nil) { load($0); return true }
        #endif
    }
}

enum UITestHooks { static let enabled = ProcessInfo.processInfo.arguments.contains("-uitest") }

extension Asset {
    /// "Coordinates, photo, edited" rather than the file name "Coordinates.jpg".
    var spokenName: String {
        let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        let kindName = kind == .video ? "video" : kind == .livePhoto ? "Live Photo" : "photo"
        return "\(base), \(kindName)" + (isEdited ? ", edited" : "")
    }
}

struct AssetRow: View {
    let asset: Asset
    var body: some View {
        HStack {
            Image(systemName: asset.kind == .video ? "film" : asset.kind == .livePhoto ? "livephoto" : "photo")
                .accessibilityHidden(true)
            Text(asset.name)
            Spacer()
            if asset.isEdited {
                Text("Edited").font(.caption).foregroundColor(.secondary).accessibilityIdentifier("edited.\(asset.name)")
            }
            if UITestHooks.enabled {
                // Instrumentation only: the asset ID, for deep-link tests (macOS outline rows drop accessibilityValue).
                Text(asset.id).font(.caption2).foregroundColor(.secondary).accessibilityIdentifier("assetID.\(asset.name)")
            }
            if let review = asset.reviewStatus {
                Text(review).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// Where Photos picker / Files results land. In UI tests the inbox holds generated fixtures.
struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import").font(.title2).accessibilityAddTraits(.isHeader)
            if model.inbox.isEmpty { Text("Nothing to import").foregroundColor(.secondary) }
            ForEach(model.inbox, id: \.self) { url in
                Button(url.lastPathComponent) {
                    model.importFiles([url])
                    isPresented = false
                }
                .accessibilityIdentifier("inbox.\(url.lastPathComponent)")
            }
            Button("Cancel") { isPresented = false }.accessibilityIdentifier("importCancel")
        }
        .padding()
        .frame(minWidth: 320)
    }
}

struct SelectMoreSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select More Photos").font(.title2).accessibilityAddTraits(.isHeader)
            ForEach(model.hiddenAssets) { a in
                Button(a.name) { model.allow(a.id); isPresented = false }.accessibilityIdentifier("allow.\(a.name)")
            }
            Button("Done") { isPresented = false }.accessibilityIdentifier("selectMoreDone")
        }
        .padding()
        .frame(minWidth: 320)
    }
}

struct EditorRouter: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var body: some View {
        if let a = model.asset(id) {
            if a.kind == .video {
                VideoEditorView(asset: a)
            } else {
                PhotoEditorView(asset: a)
            }
        } else {
            Text("Missing")
        }
    }
}
