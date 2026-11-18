import ProofKit
import SwiftUI

@main
struct ProofSheetApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    if let id = Continuity.assetID(from: url), model.asset(id) != nil { model.selection = id }
                }
                .onContinueUserActivity(Continuity.activityType) { activity in
                    guard let info = activity.userInfo, let handoff = Continuity.decode(info), model.asset(handoff.assetID) != nil else { return }
                    model.update(handoff.assetID, photo: handoff.recipe)
                    model.selection = handoff.assetID
                }
        }
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Paste Edits") { model.pasteEditsToAllOtherPhotos(except: model.selection) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(model.clipboard == nil)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) var scheme
    @Environment(\.layoutDirection) var direction

    var body: some View {
        NavigationView {
            LibraryView()
            Text("Select a photo or video").foregroundColor(.secondary).accessibilityIdentifier("emptyEditor")
        }
        .overlay(probes, alignment: .bottomTrailing)
    }

    /// Zero-size elements UI tests read to confirm appearance and layout direction.
    var probes: some View {
        VStack {
            Text("").accessibilityIdentifier("appearanceProbe").accessibilityValue(scheme == .dark ? "dark" : "light")
            Text("").accessibilityIdentifier("layoutProbe").accessibilityValue(direction == .rightToLeft ? "rightToLeft" : "leftToRight")
        }
        .frame(width: 1, height: 1)
        .opacity(0.01)
        .accessibilityHidden(false)
    }
}
