import SwiftUI
import CompanionCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "sources"

    var body: some View {
        TabView(selection: $tab) {
            SourcesSettings(model: model).tabItem { Text("Sources") }.tag("sources")
            GoogleSettings(model: model).tabItem { Text("Google") }.tag("google")
            CalendarSettings(model: model).tabItem { Text("Calendars") }.tag("calendars")
            ProviderSettings(model: model).tabItem { Text("AI Providers") }.tag("providers")
            SafetySettings(model: model).tabItem { Text("Safety") }.tag("safety")
            GeneralSettings(model: model).tabItem { Text("General") }.tag("general")
            DataSettings(model: model).tabItem { Text("Data") }.tag("data")
        }
        .padding(16)
        .id(model.refreshToken)
    }
}

struct SourcesSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Observed folders") {
                ForEach(model.env.indexing.roots()) { root in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "folder")
                            Text((root.path as NSString).abbreviatingWithTildeInPath).bold()
                            Spacer()
                            Text("\(model.env.indexing.assets(rootID: root.id).count) files").foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) { model.removeRoot(root) }
                        }
                        HStack {
                            Toggle("Read contents", isOn: Binding(get: { root.extractContent }, set: { var r = root; r.extractContent = $0; model.updateRoot(r) }))
                            Toggle("Protected (never suggest changes)", isOn: Binding(get: { root.isProtected }, set: { var r = root; r.isProtected = $0; model.updateRoot(r) }))
                            Toggle("Enabled", isOn: Binding(get: { root.enabled }, set: { var r = root; r.enabled = $0; model.updateRoot(r) }))
                        }.toggleStyle(.checkbox)
                        DisclosureEditor(policy: root.disclosure) { p in var r = root; r.disclosure = p; model.updateRoot(r) }
                        if let s = root.lastScanAt { Text("Last checked \(s.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                Button("Add Folder…") { model.addFolder() }
                Text("Removing a folder purges its index, previews and cached excerpts. Your files are never changed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Copy-only rules (off by default)") {
                ForEach(model.env.copyRules.all()) { rule in
                    HStack {
                        Text("Copy new “\(rule.pattern)” once into \((rule.destination as NSString).lastPathComponent) — \(rule.copiedFiles)/\(rule.maxFiles) files")
                        Spacer()
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { try? model.env.copyRules.setEnabled(rule.id, $0); model.reload() })).labelsHidden()
                        Button("Delete") { try? model.env.copyRules.delete(rule.id); model.reload() }
                    }
                }
                CopyRuleCreator(model: model)
            }
            Section("Working copies folder") {
                HStack {
                    Text((model.env.paths.managedWorkspaces.path as NSString).abbreviatingWithTildeInPath)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: model.env.paths.managedWorkspaces, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([model.env.paths.managedWorkspaces])
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct CopyRuleCreator: View {
    @ObservedObject var model: AppModel
    @State private var pattern = "*.pdf"
    @State private var rootID: UUID?
    @State private var maxFiles = 25
    var body: some View {
        HStack {
            Picker("From", selection: $rootID) {
                Text("Choose folder").tag(UUID?.none)
                ForEach(model.env.indexing.roots()) { Text($0.url.lastPathComponent).tag(UUID?.some($0.id)) }
            }.frame(width: 200)
            TextField("Pattern", text: $pattern).frame(width: 100)
            Stepper("Max \(maxFiles) files", value: $maxFiles, in: 1...200)
            Button("Create (disabled)") {
                guard let rootID else { return }
                let dest = model.env.copies.folder(for: model.selectedProject)
                _ = try? model.env.copyRules.create(rootID: rootID, pattern: pattern, destination: dest, maxFiles: maxFiles)
                model.reload()
            }.disabled(rootID == nil)
        }
    }
}

struct GoogleSettings: View {
    @ObservedObject var model: AppModel
    @State private var mode: GoogleAccessMode = .selectedDocuments
    @State private var link = ""
    @State private var busy = false

    var body: some View {
        Form {
            if !model.env.googleAuth.config.isConfigured {
                Section {
                    Label("Google sign-in is not configured in this build (no OAuth client ID). Local folders, calendar and AI features still work.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section("Account") {
                let accounts = model.env.googleAuth.accounts()
                ForEach(accounts) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.displayIdentity).bold()
                            Text("Status: \(a.status.rawValue) · scopes: \(a.scopes.filter { $0.contains("drive") }.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect…") { Task { await model.disconnectGoogle(a, revoke: true) } }
                    }
                }
                if accounts.isEmpty {
                    Picker("Access", selection: $mode) {
                        Text("Selected documents (recommended)").tag(GoogleAccessMode.selectedDocuments)
                        Text("Also discover titles (metadata)").tag(GoogleAccessMode.metadataDiscovery)
                        Text("Broad reading").tag(GoogleAccessMode.broadReading)
                    }
                    Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
                    Button(busy ? "Waiting for browser…" : "Connect Google Account…") {
                        busy = true
                        Task { await model.connectGoogle(mode: mode); busy = false }
                    }.disabled(busy || !model.env.googleAuth.config.isConfigured)
                    if busy { Button("Cancel sign-in") { model.env.googleAuth.cancelSignIn() } }
                    Text("Sign-in happens in your browser. A Google login does not authorize sending documents to an AI provider.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Documents") {
                HStack {
                    TextField("Paste a Google Docs link", text: $link)
                    Button("Add") { Task { await model.addGoogleDocument(link); link = "" } }.disabled(link.isEmpty)
                    Button("Choose from Google Drive…") { model.openGooglePicker() }
                }
                ForEach(model.env.cloudDocs.assets()) { c in
                    VStack(alignment: .leading) {
                        CloudCard(model: model, asset: c)
                        DisclosureEditor(policy: c.disclosure) { p in try? model.env.cloudDocs.setDisclosure(c.id, p); model.env.approvals.bumpPolicyVersion(); model.reload() }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct CalendarSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Text("macOS grants full calendar access to read events. “Read only in Companion” is Companion's own policy: it never changes a calendar unless you designate it below and approve each change.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.env.calendar.isAuthorized {
                    Button("Connect Calendar…") { Task { await model.requestCalendarAccess() } }
                }
            }
            if model.env.calendar.isAuthorized {
                Section("Calendars") {
                    ForEach(model.env.calendar.source.calendars()) { c in
                        HStack {
                            Text(c.title); Text(c.sourceTitle).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Toggle("Read", isOn: binding(Settings.selectedCalendars, c.id)).toggleStyle(.checkbox)
                            Toggle("May receive changes", isOn: binding(Settings.writableCalendars, c.id)).toggleStyle(.checkbox)
                                .disabled(!c.allowsModifications || c.isSubscribed)
                        }
                    }
                    Text(model.env.calendar.freshnessLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    func binding(_ key: SettingKey<[String]>, _ id: String) -> Binding<Bool> {
        Binding(get: { model.env.settings.get(key).contains(id) }, set: { on in
            var v = model.env.settings.get(key)
            if on { if !v.contains(id) { v.append(id) } } else { v.removeAll { $0 == id } }
            model.env.settings.set(key, v)
            model.env.approvals.bumpPolicyVersion()
            model.refreshCalendar()
        })
    }
}

struct ProviderSettings: View {
    @ObservedObject var model: AppModel
    @State private var keys: [ProviderID: String] = [:]
    @State private var testResult: [ProviderID: String] = [:]

    var body: some View {
        Form {
            Section {
                Text("Your own API keys are stored in the macOS Keychain and never written to logs, exports or prompts. Search and file opening work without any key.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Default provider", selection: Binding(get: { model.env.settings.get(Settings.defaultProvider) },
                                                              set: { model.env.settings.set(Settings.defaultProvider, $0); model.reload() })) {
                    ForEach(ProviderID.allCases) { Text($0.displayName).tag($0) }
                }
            }
            ForEach(ProviderID.allCases) { p in
                Section(p.displayName) {
                    HStack {
                        SecureField(model.env.providers.hasKey(p) ? "Key saved in Keychain" : "API key", text: Binding(get: { keys[p] ?? "" }, set: { keys[p] = $0 }))
                        Button("Save") {
                            do { try model.env.providers.setKey(keys[p] ?? "", for: p); keys[p] = ""; testResult[p] = "Saved." }
                            catch { testResult[p] = error.localizedDescription }
                            model.reload()
                        }.disabled((keys[p] ?? "").isEmpty)
                        if model.env.providers.hasKey(p) { Button("Remove") { try? model.env.providers.removeKey(p); model.reload() } }
                    }
                    TextField("Model", text: Binding(get: { model.env.providers.model(for: p) }, set: { model.env.providers.setModel($0, for: p) }))
                    HStack {
                        Button("Test connection") {
                            testResult[p] = "Testing with a tiny non-personal prompt…"
                            Task {
                                do { let r = try await model.env.providers.testConnection(p); testResult[p] = "OK — replied “\(r.prefix(40))”" }
                                catch { testResult[p] = error.localizedDescription }
                            }
                        }.disabled(!model.env.providers.hasKey(p))
                        if let r = testResult[p] { Text(r).font(.caption) }
                    }
                    Link("Data retention policy", destination: p.dataPolicyURL).font(.caption)
                }
            }
            Section("Monthly budget") {
                Stepper(value: Binding(get: { model.env.settings.get(Settings.monthlyBudgetUSD) }, set: { model.env.settings.set(Settings.monthlyBudgetUSD, $0); model.reload() }),
                        in: 1...500, step: 1) { Text(String(format: "$%.0f per month (warning at 80%%)", model.env.settings.get(Settings.monthlyBudgetUSD))) }
            }
        }.formStyle(.grouped)
    }
}

struct SafetySettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("File safety") {
                Picker("Mode", selection: Binding(get: { model.env.settings.get(Settings.safetyMode) },
                                                  set: { model.env.settings.set(Settings.safetyMode, $0); model.env.approvals.bumpPolicyVersion(); model.reload() })) {
                    Text("Observe and suggest (all user-file writes disabled)").tag(SafetyMode.observeAndSuggest)
                    Text("Allow reviewed changes I approve").tag(SafetyMode.reviewedChanges)
                }.pickerStyle(.radioGroup)
                Text("Even with reviewed changes allowed, every move, rename, replacement, calendar change or Google Docs edit needs fresh approval of the exact plan. Deletion is never available.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("At most \(model.env.settings.get(Settings.maxOperationsPerApproval)) operations per approval",
                        value: Binding(get: { model.env.settings.get(Settings.maxOperationsPerApproval) },
                                       set: { model.env.settings.set(Settings.maxOperationsPerApproval, $0); model.reload() }), in: 1...20)
            }
            Section("Pause") {
                Toggle("Pause all work", isOn: Binding(get: { model.isPaused }, set: { _ in model.togglePause() }))
                Text("Pausing cancels queued work and blocks new actions. It does not reverse completed changes.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { model.env.settings.get(Settings.launchAtLogin) }, set: { model.setLaunchAtLogin($0); model.reload() }))
                Text("Status: \(model.loginItemStatus)").font(.caption).foregroundStyle(.secondary)
            }
            Section("Companion icon") {
                Slider(value: Binding(get: { model.env.settings.get(Settings.avatarSize) }, set: { model.env.settings.set(Settings.avatarSize, $0.rounded()); model.reload() }),
                       in: 40...96, step: 4) { Text("Size \(Int(model.env.settings.get(Settings.avatarSize))) pt") }
                Stepper("Hover delay \(model.env.settings.get(Settings.hoverDelayMs)) ms", value: Binding(get: { model.env.settings.get(Settings.hoverDelayMs) },
                        set: { model.env.settings.set(Settings.hoverDelayMs, $0); model.reload() }), in: 100...1500, step: 50)
                Stepper("Close delay \(model.env.settings.get(Settings.hoverExitDelayMs)) ms", value: Binding(get: { model.env.settings.get(Settings.hoverExitDelayMs) },
                        set: { model.env.settings.set(Settings.hoverExitDelayMs, $0); model.reload() }), in: 100...2000, step: 50)
                Toggle("Reduce motion (static icon)", isOn: Binding(get: { model.env.settings.get(Settings.reduceMotion) }, set: { model.env.settings.set(Settings.reduceMotion, $0); model.reload() }))
                Toggle("Presentation mode (hide icon and notifications)", isOn: Binding(get: { model.presentationMode }, set: { _ in model.togglePresentationMode() }))
                Text("Shortcut: ⌃⌥Space opens Companion. The menu bar icon is always available.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Proactive notifications", isOn: Binding(get: { model.env.settings.get(Settings.notificationsEnabled) }, set: { v in Task { await model.setNotifications(v) } }))
                Stepper("At most \(model.env.settings.get(Settings.maxNotificationsPerDay)) per day", value: Binding(get: { model.env.settings.get(Settings.maxNotificationsPerDay) },
                        set: { model.env.settings.set(Settings.maxNotificationsPerDay, $0); model.reload() }), in: 0...5)
                HStack {
                    Stepper("Quiet from \(model.env.settings.get(Settings.quietHoursStart)):00", value: Binding(get: { model.env.settings.get(Settings.quietHoursStart) },
                            set: { model.env.settings.set(Settings.quietHoursStart, $0); model.reload() }), in: 0...23)
                    Stepper("until \(model.env.settings.get(Settings.quietHoursEnd)):00", value: Binding(get: { model.env.settings.get(Settings.quietHoursEnd) },
                            set: { model.env.settings.set(Settings.quietHoursEnd, $0); model.reload() }), in: 0...23)
                }
            }
            Section("Updates") {
                Picker("Channel", selection: Binding(get: { model.env.settings.get(Settings.updateChannel) }, set: { model.env.settings.set(Settings.updateChannel, $0) })) {
                    Text("Stable").tag("stable"); Text("Beta").tag("beta")
                }
                Text("Companion \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")). Updates are offered, never installed silently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct DataSettings: View {
    @ObservedObject var model: AppModel
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Export & backup") {
                Button("Export projects, memories and filing profile…") {
                    do { let url = try model.env.portability.export(); NSWorkspace.shared.activateFileViewerSelecting([url]); message = "Exported." }
                    catch { message = error.localizedDescription }
                }
                Button("Back up database now") {
                    do { let url = try model.env.portability.backupDatabase(); message = "Backup saved: \(url.lastPathComponent)" }
                    catch { message = error.localizedDescription }
                }
                Text("Exports contain no API keys or tokens. Restoring on another Mac requires granting folders and keys again.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Prepare to uninstall") {
                Button("Prepare to uninstall…") {
                    do {
                        model.setLaunchAtLogin(false)
                        let r = try model.env.portability.prepareToUninstall(exportFirst: true, removeProviderKeys: true)
                        message = (["Paused. Unresolved actions: \(r.unresolvedActions).", r.exportedTo.map { "Exported to \($0.path)." } ?? ""] + r.notes).joined(separator: " ")
                        model.reload()
                    } catch { message = error.localizedDescription }
                }
                Button("Remove Companion's app data…", role: .destructive) { confirmRemove = true }
                Text("Your source files, Google documents and working-copy folder are never deleted.").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove app data?", isPresented: $confirmRemove) {
            Button("Remove and quit", role: .destructive) { try? model.env.portability.removeAppData(); NSApp.terminate(nil) }
        } message: {
            Text("This permanently deletes:\n" + model.env.portability.appDataRemovalPreview().map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
                 + "\n\nIt cannot be undone. Keychain entries, provider-side data and Google access must be removed separately.")
        }
    }
}
