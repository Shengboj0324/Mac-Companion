import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import CompanionCore

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case today, continueWork, projects, find, ask, organize, memory, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .continueWork: return "Continue"
        case .projects: return "Projects"
        case .find: return "Find Files"
        case .ask: return "Ask"
        case .organize: return "Organize"
        case .memory: return "Memory & Activity"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .continueWork: return "arrow.uturn.forward.circle"
        case .projects: return "folder"
        case .find: return "magnifyingglass"
        case .ask: return "bubble.left.and.text.bubble.right"
        case .organize: return "square.grid.2x2"
        case .memory: return "brain"
        case .settings: return "gearshape"
        }
    }
}

enum AvatarState: Equatable { case idle, working, attention, paused, awaitingApproval }

/// Main-actor view model bridging CompanionCore services to the UI, plus the
/// background loops (indexing queue, reconciliation scans, calendar and Google refresh).
@MainActor
final class AppModel: ObservableObject {
    let env: CompanionEnvironment
    @Published var section: WorkspaceSection = .today
    @Published var projects: [Project] = []
    @Published var selectedProjectID: UUID?
    @Published var suggestions: [Suggestion] = []
    @Published var pendingProposals: [ActionRun] = []
    @Published var avatarState: AvatarState = .idle
    @Published var banner: String?
    @Published var reviewPlan: ActionRun?
    @Published var indexingPending = 0
    @Published var refreshToken = UUID()

    var openWorkspace: ((WorkspaceSection?) -> Void)?
    var showOnboarding: (() -> Void)?

    private var watcher: FileWatcher?
    private var loops: [Task<Void, Never>] = []
    private var activeRoots: [URL] = []
    private var lastNewAssetIDs = Set<UUID>()

    init(env: CompanionEnvironment) {
        self.env = env
        reload()
    }

    // MARK: Lifecycle

    func start() {
        resolveBookmarks()
        Task { await env.startupMaintenance(); reload() }
        startWatching()
        loops.append(loop(every: 2) { [weak self] in self?.tickIndexing() })
        loops.append(loop(every: 30 * 60) { [weak self] in self?.reconcileScan() })
        loops.append(loop(every: 15 * 60) { [weak self] in self?.refreshCalendar() })
        loops.append(Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.pollGoogle()
                backoff = ok ? 1 : min(backoff * 2, 8)
                // Reduced background work on battery.
                let onBattery = ProcessInfo.processInfo.isLowPowerModeEnabled
                let minutes = self.env.settings.get(Settings.googlePollMinutes) * backoff * (onBattery ? 3 : 1)
                try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
            }
        })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onWake() }
        }
        refreshCalendar()
        reconcileScan()
    }

    func stop() {
        loops.forEach { $0.cancel() }
        watcher?.stop()
        for url in activeRoots { url.stopAccessingSecurityScopedResource() }
    }

    private func loop(every seconds: Double, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                body()
            }
        }
    }

    /// On wake: reconcile once, discard stale reminders and refresh freshness labels.
    private func onWake() {
        env.cloudDocs.markAllCachedIfStale(olderThan: 15 * 60)
        reconcileScan()
        refreshCalendar()
        Task { _ = await pollGoogle() }
    }

    // MARK: Data refresh

    func reload() {
        projects = env.projects.all()
        if selectedProjectID == nil { selectedProjectID = env.projects.lastActive?.id }
        suggestions = env.suggestions.today()
        pendingProposals = env.executor.pendingProposals()
        indexingPending = env.indexing.pendingCount
        updateAvatarState()
        refreshToken = UUID()
    }

    func updateAvatarState() {
        if isPaused { avatarState = .paused }
        else if !pendingProposals.isEmpty { avatarState = .awaitingApproval }
        else if indexingPending > 0 { avatarState = .working }
        else if suggestions.contains(where: { $0.kind == .materialsReady }) { avatarState = .attention }
        else { avatarState = .idle }
    }

    var isPaused: Bool { env.settings.get(Settings.paused) }
    var presentationMode: Bool { env.settings.get(Settings.presentationMode) }

    func togglePause() { env.setPaused(!isPaused); reload() }
    func togglePresentationMode() { env.settings.set(Settings.presentationMode, !presentationMode); reload() }

    // MARK: Indexing

    private func tickIndexing() {
        guard !isPaused else { return }
        let before = env.indexing.pendingCount
        if before > 0 {
            env.indexing.processPending(limit: 25)
            // Optional copy-only rules apply to newly added files only.
            let fresh = env.indexing.recentAssets(limit: 50).filter { !lastNewAssetIDs.contains($0.id) }
            if !fresh.isEmpty { env.copyRules.apply(newAssets: fresh); lastNewAssetIDs.formUnion(fresh.map(\.id)) }
        }
        let after = env.indexing.pendingCount
        if before != after || indexingPending != after { indexingPending = after; updateAvatarState() }
    }

    func reconcileScan() {
        guard !isPaused else { return }
        lastNewAssetIDs.formUnion(env.indexing.assets().map(\.id))
        env.indexing.scanAll()
        for wc in env.copies.all() { env.copies.refreshState(wc.id) }
        reload()
    }

    private func startWatching() {
        let indexing = env.indexing
        watcher = FileWatcher { paths in
            DispatchQueue.main.async { for p in paths.prefix(500) { indexing.reconcile(path: p) } }
        }
        watcher?.watch(env.indexing.roots().filter(\.enabled).map(\.path) + [env.paths.managedWorkspaces.path])
    }

    /// Security-scoped bookmarks keep folder grants across launches (sandboxed builds).
    private func resolveBookmarks() {
        for root in env.indexing.roots() {
            guard let data = root.bookmark else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { activeRoots.append(url) }
                if stale { banner = "Access to “\(url.lastPathComponent)” needs to be renewed in Settings → Sources." }
            }
        }
    }

    // MARK: Sources

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Observe Folder"
        panel.message = "Companion will index this folder locally. Nothing is uploaded without your separate permission."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        _ = url.startAccessingSecurityScopedResource()
        activeRoots.append(url)
        do {
            let root = try env.indexing.addRoot(url, bookmark: bookmark)
            env.indexing.scan(root)
            startWatching()
            reload()
        } catch { banner = error.localizedDescription }
    }

    func removeRoot(_ root: Root) {
        do { try env.indexing.removeRoot(root.id); env.approvals.bumpPolicyVersion(); startWatching(); reload() }
        catch { banner = error.localizedDescription }
    }

    func updateRoot(_ root: Root) {
        try? env.indexing.updateRoot(root)
        env.approvals.bumpPolicyVersion()
        reload()
    }

    /// Dropping a document on the avatar adds a reference (never a copy).
    func addDroppedFiles(_ urls: [URL]) {
        var added = 0
        for url in urls {
            guard let asset = try? env.indexing.addReference(url) else { continue }
            if let pid = selectedProjectID { _ = try? env.projects.addItem(projectID: pid, kind: .file, targetID: asset.id, reason: "Dropped on Companion") }
            added += 1
        }
        if added > 0 {
            banner = "Added \(added) reference\(added == 1 ? "" : "s")\(selectedProject.map { " to \($0.name)" } ?? ""). Files stay where they are."
        }
        reload()
    }

    // MARK: Projects

    var selectedProject: Project? { selectedProjectID.flatMap(env.projects.project) }

    func createProject(_ name: String) {
        do {
            let p = try env.projects.create(name: name)
            selectedProjectID = p.id
            env.projects.markOpened(p.id)
            reload()
        } catch { banner = error.localizedDescription }
    }

    func open(_ asset: FileAsset) {
        guard FileManager.default.fileExists(atPath: asset.path) else { banner = "“\(asset.name)” is missing. It may have been moved outside Companion's folders."; return }
        NSWorkspace.shared.open(asset.url)
        if let p = selectedProjectID { env.projects.markOpened(p) }
    }

    func reveal(_ asset: FileAsset) { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }

    func open(_ cloud: CloudAsset) {
        guard let s = cloud.canonicalURL, let url = URL(string: s), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Proposals and approvals

    func proposeWorkingCopy(of asset: FileAsset) {
        let dest = WorkingCopyService.uniqueDestination(for: asset.name, in: env.copies.folder(for: selectedProject))
        let plan = ActionPlan(title: "Working copy of \(asset.name)",
                              operations: [PlannedOperation(kind: .copyFile, sourcePath: asset.path, sourceHash: asset.contentHash ?? (try? Hashing.sha256Hex(fileAt: asset.url)),
                                                            destinationPath: dest.path, reason: "You asked for a working copy")],
                              initiator: "user", projectID: selectedProjectID, createdAt: Date())
        submit(plan)
    }

    func submit(_ plan: ActionPlan) {
        do { reviewPlan = try env.executor.propose(plan); reload() }
        catch { banner = error.localizedDescription }
    }

    func review(_ run: ActionRun) { reviewPlan = run }

    /// The only place an approval grant is issued: the trusted review sheet.
    func approve(_ plan: ActionPlan, selected: Set<Int>) async -> ActionRun? {
        var final = plan
        if selected.count != plan.operations.count {
            // Editing the selection creates a new plan (new hash); the old one is rejected.
            try? env.executor.reject(plan.id)
            final = ActionPlan(title: plan.title, operations: plan.operations.enumerated().filter { selected.contains($0.offset) }.map(\.element),
                               initiator: plan.initiator, projectID: plan.projectID, createdAt: Date())
            guard (try? env.executor.propose(final)) != nil else { return nil }
        }
        try? env.executor.markReviewed(final.id)
        let grant = env.approvals.issue(for: final, userConfirmedAt: Date())
        avatarState = .working
        let run = await env.executor.execute(final.id, grant: grant)
        reload()
        return run
    }

    func reject(_ plan: ActionPlan) {
        try? env.executor.reject(plan.id)
        reviewPlan = nil
        reload()
    }

    // MARK: Calendar & Google

    func refreshCalendar() {
        guard env.calendar.isAuthorized else { return }
        env.calendar.refresh()
        reload()
    }

    func requestCalendarAccess() async {
        _ = await env.calendar.source.requestAccess()
        if env.calendar.isAuthorized && env.settings.get(Settings.selectedCalendars).isEmpty {
            // Selection starts empty: the user chooses calendars explicitly.
            banner = "Calendar access granted. Choose which calendars Companion may read in Settings → Calendars."
        }
        refreshCalendar()
    }

    @discardableResult
    func pollGoogle() async -> Bool {
        guard !isPaused else { return true }
        var ok = true
        for account in env.googleAuth.accounts() where account.status == .connected {
            do { try await env.cloudDocs.pollChanges(accountID: account.id) } catch { ok = false }
        }
        reload()
        return ok
    }

    func connectGoogle(mode: GoogleAccessMode) async {
        do {
            _ = try await env.googleAuth.signIn(mode: mode, openURL: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } })
            banner = "Google account connected. Add documents by link or with “Choose from Google Drive”."
        } catch CompanionError.cancelled {
            banner = "Google sign-in was cancelled."
        } catch { banner = error.localizedDescription }
        reload()
    }

    func disconnectGoogle(_ account: ConnectorAccount, revoke: Bool) async {
        do {
            try await env.googleAuth.disconnect(account.id, revoke: revoke, purge: { [env] in try env.cloudDocs.purge(accountID: $0) })
            env.approvals.bumpPolicyVersion()
        } catch { banner = error.localizedDescription }
        reload()
    }

    func addGoogleDocument(_ locator: String) async {
        guard let account = env.googleAuth.accounts().first(where: { $0.status == .connected }) else {
            banner = "Connect a Google account first."; return
        }
        do {
            let asset = try await env.cloudDocs.addDocument(accountID: account.id, locator: locator)
            if let pid = selectedProjectID { _ = try? env.projects.addItem(projectID: pid, kind: .cloudDoc, targetID: asset.id) }
            banner = "Added “\(asset.name)”. \(asset.coverage.map { $0.summary } ?? "")"
        } catch { banner = error.localizedDescription }
        reload()
    }

    func openGooglePicker() {
        if let url = env.googleAuth.config.pickerURL { NSWorkspace.shared.open(url) }
        else { banner = "The Google Drive picker is not configured in this build. Paste a document link instead." }
    }

    // MARK: Settings helpers

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !Bundle.main.bundlePath.hasPrefix("/Volumes/") else {
            banner = "Install Companion in Applications before enabling login launch."; return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            env.settings.set(Settings.launchAtLogin, enabled)
        } catch {
            banner = "macOS did not allow login launch: \(error.localizedDescription). You can approve it in System Settings → General → Login Items."
        }
    }

    var loginItemStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Waiting for approval in System Settings → Login Items"
        case .notRegistered: return "Off"
        case .notFound: return "Unavailable for this build"
        @unknown default: return "Unknown"
        }
    }

    func setNotifications(_ enabled: Bool) async {
        if enabled {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            env.settings.set(Settings.notificationsEnabled, granted)
            if !granted { banner = "Notifications were not allowed. Suggestions still appear in Today." }
        } else {
            env.settings.set(Settings.notificationsEnabled, false)
        }
        reload()
    }

    /// Proactive notification, gated by daily limit, quiet hours, snooze and presentation mode.
    func notifyIfAllowed(_ s: Suggestion) {
        let snooze = s.projectID.flatMap(env.projects.project)?.snoozedUntil
        guard env.notifications.mayNotify(projectSnoozedUntil: snooze) else { return }
        let content = UNMutableNotificationContent()
        content.title = s.title
        // Private titles stay out of the lock screen preview body.
        content.body = "Open Companion to see why."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id, content: content, trigger: nil))
        env.notifications.record(kind: s.kind.rawValue, projectID: s.projectID)
    }
}
