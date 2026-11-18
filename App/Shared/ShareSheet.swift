import SwiftUI

/// The system share sheet (iOS: UIActivityViewController, which includes Save Image;
/// macOS: NSSharingServicePicker), shown when `isPresented` turns true.
#if os(iOS)
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, host.presentedViewController == nil else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in isPresented = false }
        vc.popoverPresentationController?.sourceView = host.view
        DispatchQueue.main.async { host.present(vc, animated: true) }
    }
}
#else
import AppKit

struct ShareSheet: NSViewRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard isPresented else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            isPresented = false
        }
    }
}
#endif
