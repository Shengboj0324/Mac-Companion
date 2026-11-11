import Foundation

/// Typed key/value settings persisted in the app database.
public final class SettingsStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    public func get<T: Codable & Sendable>(_ key: SettingKey<T>) -> T {
        guard let row = try? db.queryOne("SELECT value FROM settings WHERE key = ?", [key.name]),
              let raw = row.string("value"),
              let wrapped = try? JSON.decode(Box<T>.self, from: raw) else { return key.defaultValue }
        return wrapped.v
    }

    public func set<T: Codable & Sendable>(_ key: SettingKey<T>, _ value: T) {
        guard let raw = try? JSON.encode(Box(v: value)) else { return }
        try? db.execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        [key.name, raw])
    }

    private struct Box<T: Codable>: Codable { let v: T }
}

public struct SettingKey<T: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: T
    public init(_ name: String, default value: T) { self.name = name; self.defaultValue = value }
}

/// Product defaults. New capabilities always start disabled (spec §18).
public enum Settings {
    public static let onboardingComplete = SettingKey("onboarding.complete", default: false)
    public static let safetyMode = SettingKey("safety.mode", default: SafetyMode.observeAndSuggest)
    public static let policyVersion = SettingKey("policy.version", default: 1)
    public static let paused = SettingKey("app.paused", default: false)
    public static let presentationMode = SettingKey("app.presentationMode", default: false)
    public static let launchAtLogin = SettingKey("app.launchAtLogin", default: false)
    public static let notificationsEnabled = SettingKey("notifications.enabled", default: false)
    public static let maxNotificationsPerDay = SettingKey("notifications.maxPerDay", default: 2)
    public static let quietHoursStart = SettingKey("notifications.quietStart", default: 22)
    public static let quietHoursEnd = SettingKey("notifications.quietEnd", default: 8)
    public static let dailyPrepHour = SettingKey("suggestions.dailyHour", default: 8)

    public static let avatarSkin = SettingKey("avatar.skin", default: "circle")
    public static let avatarSize = SettingKey("avatar.size", default: 56.0)
    public static let avatarLocked = SettingKey("avatar.locked", default: false)
    public static let hoverDelayMs = SettingKey("hover.delayMs", default: 300)
    public static let hoverExitDelayMs = SettingKey("hover.exitDelayMs", default: 400)
    public static let reduceMotion = SettingKey("avatar.reduceMotion", default: false)
    public static let avatarPositions = SettingKey("avatar.positions", default: [String: [Double]]())

    public static let defaultProvider = SettingKey("provider.default", default: ProviderID.anthropic)
    public static let providerModels = SettingKey("provider.models", default: ProviderID.defaultModels)
    public static let monthlyBudgetUSD = SettingKey("budget.monthlyUSD", default: 10.0)
    public static let budgetWarnFraction = SettingKey("budget.warnFraction", default: 0.8)

    public static let selectedCalendars = SettingKey("calendar.selected", default: [String]())
    public static let writableCalendars = SettingKey("calendar.writable", default: [String]())
    public static let calendarPastDays = SettingKey("calendar.pastDays", default: 14)
    public static let calendarFutureDays = SettingKey("calendar.futureDays", default: 60)

    public static let googlePollMinutes = SettingKey("google.pollMinutes", default: 5.0)
    public static let lastActiveProject = SettingKey("workspace.lastProject", default: String?.none)
    public static let maxOperationsPerApproval = SettingKey("policy.maxOps", default: 20)
    public static let approvalTTLSeconds = SettingKey("policy.approvalTTL", default: 60.0)
    public static let recoveryRetentionDays = SettingKey("retention.recoveryDays", default: 30)
    public static let actionMetadataRetentionDays = SettingKey("retention.actionDays", default: 90)
    public static let updateChannel = SettingKey("updates.channel", default: "stable")
    public static let crashReportingOptIn = SettingKey("diagnostics.crashOptIn", default: false)
}

public enum SafetyMode: String, Codable, Sendable, CaseIterable {
    /// Read approved sources and maintain app data only. All user-file writes disabled.
    case observeAndSuggest
    /// Allow reviewed, explicitly approved plans to execute.
    case reviewedChanges
}
