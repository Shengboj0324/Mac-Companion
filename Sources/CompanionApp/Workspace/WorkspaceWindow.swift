import AppKit
import SwiftUI
import CompanionCore

final class WorkspaceWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }   // Escape dismisses
}

@MainActor
final class WorkspaceWindowController {
    private let window: WorkspaceWindow
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.title = "Companion"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.setFrameAutosaveName("CompanionWorkspace")
    }

    var isVisible: Bool { window.isVisible }

    /// Opens near the active display (the one with the pointer).
    func show() {
        model.reload()
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), window.screen != screen || !window.isVisible {
            let vf = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

struct WorkspaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(WorkspaceSection.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.title, systemImage: s.symbol)
                    .badge(s == .organize ? model.pendingProposals.count : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { StatusFooter(model: model) }
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(banner).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { model.banner = nil }.buttonStyle(.borderless)
                    }
                    .padding(10).background(Color.accentColor.opacity(0.12))
                }
                if model.isPaused {
                    HStack { Image(systemName: "pause.circle"); Text("Paused — no indexing, requests or changes run until you resume."); Spacer()
                        Button("Resume") { model.togglePause() } }
                        .padding(10).background(Color.orange.opacity(0.15))
                }
                Group {
                    switch model.section {
                    case .today: TodayView(model: model)
                    case .continueWork: ContinueView(model: model)
                    case .projects: ProjectsView(model: model)
                    case .find: FindView(model: model)
                    case .ask: AskView(model: model)
                    case .organize: OrganizeView(model: model)
                    case .memory: MemoryActivityView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $model.reviewPlan) { run in PlanReviewView(model: model, run: run) }
    }
}

struct StatusFooter: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if model.indexingPending > 0 { Label("Indexing \(model.indexingPending) file(s)…", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
            Label(model.env.settings.get(Settings.safetyMode) == .observeAndSuggest ? "Observe and suggest" : "Reviewed changes allowed",
                  systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            let b = model.env.budget.status()
            Label(String(format: "$%.2f of $%.0f this month", b.spent, b.limit), systemImage: "dollarsign.circle")
                .font(.caption).foregroundStyle(b.isWarning ? .orange : .secondary)
        }
        .padding(10)
    }
}

// MARK: Shared components

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.bold())
            if let subtitle { Text(subtitle).foregroundStyle(.secondary).font(.callout) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every file card shows location, original/working-copy status, last indexed time and availability.
struct FileCard: View {
    @ObservedObject var model: AppModel
    let asset: FileAsset
    var snippet: String?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: asset.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(asset.name).font(.headline).lineLimit(1)
                    Tag(asset.isManagedCopy ? "Working copy" : "Original", color: asset.isManagedCopy ? .purple : .teal)
                    if asset.availability != .available { Tag(asset.availability == .missing ? "Missing" : "Not available", color: .red) }
                }
                Text((asset.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let snippet, !snippet.isEmpty { Text(snippet).font(.callout).lineLimit(3) }
                HStack(spacing: 8) {
                    Text(asset.indexStatus.label)
                    if let d = asset.lastIndexedAt { Text("Indexed \(d.formatted(.relative(presentation: .named)))") }
                }.font(.caption2).foregroundStyle(.secondary)
                if let detail = asset.indexDetail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            HStack {
                Button("Open") { model.open(asset) }.accessibilityLabel("Open \(asset.name) in its app")
                Menu {
                    Button("Reveal in Finder") { model.reveal(asset) }
                    Button("Quick Look") { QuickLook.show(asset.url) }
                    if let pid = model.selectedProjectID {
                        Button("Add to \(model.selectedProject?.name ?? "project")") {
                            _ = try? model.env.projects.addItem(projectID: pid, kind: .file, targetID: asset.id); model.reload()
                        }
                    }
                    Button("Make a working copy…") { model.proposeWorkingCopy(of: asset) }
                    if let onRemove { Divider(); Button("Remove card (file is kept)", action: onRemove) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 30)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct CloudCard: View {
    @ObservedObject var model: AppModel
    let asset: CloudAsset
    var snippet: String?
    var onRemove: (() -> Void)?

    var body: some View {
        let account = model.env.googleAuth.account(asset.accountID)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.blue).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(asset.name).font(.headline).lineLimit(1)
                    Tag("Google Doc · original", color: .blue)
                    Tag(asset.freshness.label, color: asset.freshness == .current ? .green : .orange)
                }
                Text(account?.displayIdentity ?? "Disconnected account").font(.caption).foregroundStyle(.secondary)
                if let snippet, !snippet.isEmpty { Text(snippet).font(.callout).lineLimit(3) }
                if let r = asset.retrievedAt { Text("Checked \(r.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary) }
                if let c = asset.coverage { Text(c.summary).font(.caption2).foregroundStyle(c.isComplete ? Color.secondary : Color.orange) }
            }
            Spacer()
            Button("Open") { model.open(asset) }
            Menu {
                Button("Refresh now") { Task { _ = try? await model.env.cloudDocs.refreshContent(asset.id, force: true); model.reload() } }
                if let onRemove { Divider(); Button("Remove card (document is kept)", action: onRemove) }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity).padding(40)
    }
}
