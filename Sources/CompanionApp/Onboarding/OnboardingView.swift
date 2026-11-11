import SwiftUI
import CompanionCore

/// First run: avatar → source path (Google or local, equally supported) →
/// optional calendar → optional provider + budget → safety mode → login/notifications.
/// Every step can be skipped; a refusal removes only its dependent feature.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let finish: () -> Void
    @State private var step = 0
    @State private var key = ""
    @State private var provider: ProviderID = .anthropic
    @State private var testMessage: String?
    private let steps = ["Welcome", "Sources", "Calendar", "AI", "Safety", "Finish"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { ForEach(steps.indices, id: \.self) { i in Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(height: 4) } }
            Group {
                switch step {
                case 0: welcome
                case 1: sources
                case 2: calendar
                case 3: ai
                case 4: safety
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < steps.count - 1 {
                    Button(step == 0 ? "Get started" : "Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Start using Companion") {
                        model.env.settings.set(Settings.onboardingComplete, true)
                        model.reload()
                        finish()
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hover. Find. Resume.").font(.largeTitle.bold())
            Text("Companion stays on your desktop as a small icon. Hover over it to find your files, see today's work and pick up where you left off.")
            Text("Choose how it looks:").bold()
            HStack(spacing: 24) {
                ForEach(SkinStore.shared.allSkins().prefix(2)) { skin in
                    VStack {
                        AvatarView(state: .idle, skin: skin, reduceMotion: true).frame(width: 64, height: 64)
                        Button(skin.displayName) { model.env.settings.set(Settings.avatarSkin, skin.id); model.reload() }
                            .buttonStyle(.bordered).tint(model.env.settings.get(Settings.avatarSkin) == skin.id ? .accentColor : .gray)
                    }
                }
            }
            Text("Indexing and memory stay on this Mac. Nothing is sent to an AI company unless you allow it for each source.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where is your work?").font(.title.bold())
            Text("Pick either — or both. You can add more later.").foregroundStyle(.secondary)
            GroupBox {
                HStack {
                    VStack(alignment: .leading) { Text("A local folder").bold(); Text("Companion observes it and indexes supported text locally.").font(.caption) }
                    Spacer()
                    Button("Choose Folder…") { model.addFolder() }
                }
                ForEach(model.env.indexing.roots()) { Label(($0.path as NSString).abbreviatingWithTildeInPath, systemImage: "checkmark.circle").font(.caption) }
            }
            GroupBox {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Selected Google Docs").bold()
                        Text(model.env.googleAuth.config.isConfigured ? "Sign in through your browser, then add documents." : "Not available in this build yet.").font(.caption)
                    }
                    Spacer()
                    Button("Connect Google…") { Task { await model.connectGoogle(mode: .selectedDocuments) } }.disabled(!model.env.googleAuth.config.isConfigured)
                }
                ForEach(model.env.googleAuth.accounts()) { Label($0.displayIdentity, systemImage: "checkmark.circle").font(.caption) }
            }
            Text("Google-only use needs no folder access, and local-only use needs no Google account.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var calendar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a calendar? (optional)").font(.title.bold())
            Text("Companion can prepare materials before scheduled study sessions. macOS asks for full calendar access to read events; Companion itself stays read-only unless you later designate a calendar for focus blocks.")
            Button(model.env.calendar.isAuthorized ? "Calendar connected" : "Connect Calendar…") { Task { await model.requestCalendarAccess() } }
                .disabled(model.env.calendar.isAuthorized)
            if model.env.calendar.isAuthorized {
                Text("Choose which calendars to read:").bold()
                ForEach(model.env.calendar.source.calendars()) { c in
                    Toggle(c.title, isOn: Binding(get: { model.env.settings.get(Settings.selectedCalendars).contains(c.id) }, set: { on in
                        var v = model.env.settings.get(Settings.selectedCalendars)
                        if on { v.append(c.id) } else { v.removeAll { $0 == c.id } }
                        model.env.settings.set(Settings.selectedCalendars, v); model.refreshCalendar()
                    }))
                }
            }
        }
    }

    var ai: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an AI provider? (optional)").font(.title.bold())
            Text("Use your own OpenAI, Anthropic or DeepSeek API key. It is stored in the Keychain. Search and opening files work without it.")
            Picker("Provider", selection: $provider) { ForEach(ProviderID.allCases) { Text($0.displayName).tag($0) } }.frame(width: 300)
            HStack {
                SecureField("API key", text: $key)
                Button("Save") {
                    do { try model.env.providers.setKey(key, for: provider); model.env.settings.set(Settings.defaultProvider, provider); key = ""; testMessage = "Saved." }
                    catch { testMessage = error.localizedDescription }
                }.disabled(key.isEmpty)
            }
            Button("Test connection") {
                testMessage = "Sending a tiny non-personal test prompt (a fraction of a cent)…"
                Task {
                    do { _ = try await model.env.providers.testConnection(provider); testMessage = "Connection works." }
                    catch { testMessage = error.localizedDescription }
                }
            }.disabled(!model.env.providers.hasKey(provider))
            if let testMessage { Text(testMessage).font(.caption) }
            Stepper(String(format: "Monthly budget: $%.0f", model.env.settings.get(Settings.monthlyBudgetUSD)),
                    value: Binding(get: { model.env.settings.get(Settings.monthlyBudgetUSD) }, set: { model.env.settings.set(Settings.monthlyBudgetUSD, $0); model.reload() }),
                    in: 1...200)
            Text("No real document is sent to validate the key.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var safety: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You stay in control").font(.title.bold())
            Label("Starting in Observe and suggest: Companion reads approved sources and keeps its own index. All writes to your files are disabled.", systemImage: "lock.shield")
            Label("Suggestions to copy, move or rename always show an exact plan first. Nothing changes until you press Apply.", systemImage: "checklist")
            Label("Companion never deletes your files, shares documents, sends messages or submits assignments.", systemImage: "hand.raised")
            Label("Local search and memory stay on this Mac. Sending context to an AI provider is a separate permission per source.", systemImage: "externaldrive.badge.checkmark")
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Almost done").font(.title.bold())
            Toggle("Open Companion at login", isOn: Binding(get: { model.env.settings.get(Settings.launchAtLogin) }, set: { model.setLaunchAtLogin($0); model.reload() }))
            Toggle("Allow up to two helpful notifications a day", isOn: Binding(get: { model.env.settings.get(Settings.notificationsEnabled) }, set: { v in Task { await model.setNotifications(v) } }))
            Text("Tip: press ⌃⌥Space anytime, or use the menu bar icon. Drop a file on the companion to add it to the current project.").foregroundStyle(.secondary)
        }
    }
}
