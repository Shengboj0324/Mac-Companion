import AppKit
import SwiftUI
import CompanionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var floating: FloatingCompanionController?
    private var workspace: WorkspaceWindowController?
    private var onboarding: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let instanceLock = SingleInstanceLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths.standard()
        guard instanceLock.acquire(at: paths.support.appendingPathComponent(".instance.lock")) else {
            // Another instance owns the database; bring it forward instead of competing.
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first { $0 != NSRunningApplication.current }?.activate()
            NSApp.terminate(nil)
            return
        }
        let env: CompanionEnvironment
        do { env = try CompanionEnvironment(paths: paths) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Companion could not open its data"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let model = AppModel(env: env)
        self.model = model
        model.openWorkspace = { [weak self] section in self?.showWorkspace(section) }
        model.showOnboarding = { [weak self] in self?.showOnboarding() }

        workspace = WorkspaceWindowController(model: model)
        floating = FloatingCompanionController(model: model)
        installStatusItem()
        hotKey = HotKey(keyCode: 49, modifiers: [.control, .option]) { [weak self] in self?.toggleWorkspace() }  // ⌃⌥Space
        model.start()

        if Bundle.main.bundlePath.hasPrefix("/Volumes/") {
            model.banner = "Companion is running from the disk image. Drag it to Applications, then open it from there. Login launch is disabled until then."
        }
        if !env.settings.get(Settings.onboardingComplete) { showOnboarding() } else { floating?.show() }
    }

    func applicationWillTerminate(_ notification: Notification) { model?.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkspace(nil); return true
    }

    // MARK: Windows

    func showWorkspace(_ section: WorkspaceSection?) {
        if let section { model?.section = section }
        workspace?.show()
    }

    func toggleWorkspace() {
        guard let workspace else { return }
        if workspace.isVisible { workspace.close() } else { showWorkspace(nil) }
    }

    func showOnboarding() {
        guard let model else { return }
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Welcome to Companion"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(model: model, finish: { [weak self] in
                self?.onboarding?.close()
                self?.floating?.show()
            }))
            w.center()
            onboarding = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar fallback

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Companion")
        item.button?.setAccessibilityLabel("Companion")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc func menuOpen() { showWorkspace(nil) }
    @objc func menuFind() { showWorkspace(.find) }
    @objc func menuAsk() { showWorkspace(.ask) }
    @objc func menuToday() { showWorkspace(.today) }
    @objc func menuSettings() { showWorkspace(.settings) }
    @objc func menuTogglePause() { model?.togglePause() }
    @objc func menuToggleCompanion() { floating?.toggleVisibility() }
    @objc func menuTogglePresentation() { model?.togglePresentationMode(); floating?.refreshVisibility() }
    @objc func menuResetPosition() { floating?.resetPosition() }
    @objc func menuQuit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        add("Open Companion  ⌃⌥Space", #selector(menuOpen))
        add("Today", #selector(menuToday))
        add("Find Files…", #selector(menuFind))
        add("Ask…", #selector(menuAsk))
        menu.addItem(.separator())
        add(model?.isPaused == true ? "Resume" : "Pause All", #selector(menuTogglePause))
        add(floating?.isVisible == true ? "Hide Companion Icon" : "Show Companion Icon", #selector(menuToggleCompanion))
        add(model?.presentationMode == true ? "Exit Presentation Mode" : "Presentation Mode", #selector(menuTogglePresentation))
        add("Reset Icon Position", #selector(menuResetPosition))
        menu.addItem(.separator())
        add("Settings…", #selector(menuSettings), ",")
        add("Quit Companion", #selector(menuQuit), "q")
    }
}
