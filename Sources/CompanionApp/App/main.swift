import AppKit
import CompanionCore

// Entry point. Companion runs as an agent app (no Dock icon): the floating
// companion, the menu bar item and a global shortcut are its entry points.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    if SnapshotRenderer.runIfRequested() { exit(0) }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
