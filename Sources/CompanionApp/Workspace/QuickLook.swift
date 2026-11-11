import AppKit
import Quartz

/// Native previews via Quick Look; full editing is delegated to the registered app.
@MainActor
enum QuickLook {
    private final class Source: NSObject, QLPreviewPanelDataSource {
        var url: URL?
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
    }
    private static let source = Source()

    static func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        source.url = url
        panel.dataSource = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}
