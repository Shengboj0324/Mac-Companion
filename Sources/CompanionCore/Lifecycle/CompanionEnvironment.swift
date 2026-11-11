import Foundation

/// Locations of app-owned data. Working copies live in a user-visible folder;
/// everything else stays in Application Support.
public struct AppPaths: Sendable {
    public let support: URL
    public let database: URL
    public let backups: URL
    public let recovery: URL
    public let exports: URL
    public let managedWorkspaces: URL

    public init(support: URL, managedWorkspaces: URL) {
        self.support = support
        self.database = support.appendingPathComponent("companion.sqlite")
        self.backups = support.appendingPathComponent("Backups", isDirectory: true)
        self.recovery = support.appendingPathComponent("Recovery", isDirectory: true)
        self.exports = support.appendingPathComponent("Exports", isDirectory: true)
        self.managedWorkspaces = managedWorkspaces
    }

    public static func standard() -> AppPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Companion", isDirectory: true)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Companion Workspaces", isDirectory: true)
        return AppPaths(support: support, managedWorkspaces: docs)
    }

    func createDirectories() throws {
        for d in [support, backups, recovery, exports] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

/// Composition root wiring every service with a single database write path.
public final class CompanionEnvironment: @unchecked Sendable {
    public let paths: AppPaths
    public let clock: Clock
    public let db: SQLiteDatabase
    public let secrets: SecretStore
    public let settings: SettingsStore
    public let activity: ActivityLog
    public let cipher: ContentCipher
    public let search: SearchIndex
    public let indexing: IndexingService
    public let projects: ProjectService
    public let copies: WorkingCopyService
    public let copyRules: CopyRuleService
    public let approvals: ApprovalAuthority
    public let executor: ActionExecutor
    public let memory: MemoryService
    public let tasks: TaskService
    public let calendar: CalendarService
    public let budget: BudgetService
    public let providers: ProviderRegistry
    public let filing: FilingProfileService
    public let googleAuth: GoogleAuthService
    public let googleAPI: GoogleAPIClient
    public let cloudDocs: CloudDocumentService
    public let retrieval: RetrievalService
    public let tools: ToolRegistry
    public let conversations: ConversationService
    public let suggestions: SuggestionEngine
    public let notifications: NotificationPolicy
    public let portability: DataPortability

    public init(paths: AppPaths, clock: Clock = SystemClock(), secrets: SecretStore = KeychainStore(),
                calendarSource: CalendarSource = EventKitCalendarSource(), transport: HTTPTransport = URLSessionTransport(),
                googleConfig: GoogleConfig = .fromBundle(), providerAdapters: [ProviderID: LLMProvider]? = nil,
                inMemoryDatabase: Bool = false) throws {
        self.paths = paths
        self.clock = clock
        try paths.createDirectories()
        db = inMemoryDatabase ? try .inMemory() : try SQLiteDatabase(path: paths.database.path)
        try Migrator.migrate(db, backupDirectory: paths.backups, now: clock.now())
        self.secrets = secrets
        settings = SettingsStore(db: db)
        activity = ActivityLog(db: db, clock: clock)
        cipher = try ContentCipher(secrets: secrets)
        search = SearchIndex(db: db, cipher: cipher)
        indexing = IndexingService(db: db, search: search, clock: clock, activity: activity)
        projects = ProjectService(db: db, clock: clock, settings: settings, search: search, activity: activity)
        copies = WorkingCopyService(db: db, clock: clock, managedRoot: paths.managedWorkspaces, indexing: indexing, activity: activity)
        copyRules = CopyRuleService(db: db, clock: clock, copies: copies, activity: activity)
        approvals = ApprovalAuthority(db: db, clock: clock, settings: settings)
        executor = ActionExecutor(db: db, clock: clock, settings: settings, approvals: approvals, indexing: indexing, activity: activity,
                                  recoveryDirectory: paths.recovery, managedRoot: paths.managedWorkspaces)
        memory = MemoryService(db: db, clock: clock, search: search, activity: activity)
        tasks = TaskService(db: db, clock: clock)
        calendar = CalendarService(db: db, clock: clock, settings: settings, source: calendarSource)
        budget = BudgetService(db: db, clock: clock, settings: settings)
        providers = ProviderRegistry(secrets: secrets, settings: settings, adapters: providerAdapters)
        filing = FilingProfileService(db: db, clock: clock, indexing: indexing)
        googleAuth = GoogleAuthService(db: db, clock: clock, secrets: secrets, transport: transport, activity: activity, config: googleConfig)
        googleAPI = GoogleAPIClient(auth: googleAuth, transport: transport)
        let drive = GoogleDrive(api: googleAPI)
        cloudDocs = CloudDocumentService(db: db, clock: clock, search: search, auth: googleAuth, drive: drive, activity: activity)
        let cloud = cloudDocs
        retrieval = RetrievalService(db: db, search: search, indexing: indexing, projects: projects, memory: memory, tasks: tasks,
                                     calendar: calendar, cloud: { cloud })
        tools = ToolRegistry(retrieval: retrieval, search: search, indexing: indexing, projects: projects, memory: memory, executor: executor,
                             calendar: calendar, copies: copies, settings: settings, clock: clock)
        conversations = ConversationService(db: db, clock: clock, settings: settings, registry: providers, budget: budget,
                                            retrieval: retrieval, tools: tools)
        suggestions = SuggestionEngine(clock: clock, projects: projects, calendar: calendar, tasks: tasks, executor: executor, copies: copies)
        notifications = NotificationPolicy(db: db, clock: clock, settings: settings)
        portability = DataPortability(db: db, clock: clock, paths: paths, settings: settings, memory: memory, projects: projects,
                                      filing: filing, providers: providers, activity: activity)
        executor.register(calendar)
        executor.register(GoogleDocsPerformer(db: db, clock: clock, drive: drive, docs: cloudDocs, cipher: cipher))
    }

    /// Pause all: cancels queued work, blocks new actions and invalidates approvals.
    /// Completed writes are not reversed.
    public func setPaused(_ paused: Bool) {
        settings.set(Settings.paused, paused)
        approvals.bumpPolicyVersion()
        activity.record(kind: "app", summary: paused ? "Paused all work" : "Resumed")
    }

    /// Housekeeping on launch/wake: reconcile interrupted actions, expire stale
    /// session context, rotate retention-bound storage.
    public func startupMaintenance() async {
        await executor.reconcileUnfinished()
        memory.expireSessionContext()
        approvals.pruneExpired()
        executor.pruneRecovery()
        activity.prune(olderThan: settings.get(Settings.actionMetadataRetentionDays))
    }

    public static func makeDefault() throws -> CompanionEnvironment { try CompanionEnvironment(paths: .standard()) }
}
