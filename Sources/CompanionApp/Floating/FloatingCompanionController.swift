import AppKit
import SwiftUI
import Combine
import CompanionCore

/// Borderless, non-activating panel that floats above ordinary windows (including
/// browsers) on every Space. Only the icon and the open menu intercept the pointer.
final class CompanionPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingCompanionController: NSObject {
    private let model: AppModel
    private let panel: CompanionPanel
    private let menuPanel: CompanionPanel
    private var hostView: AvatarHostView!
    private var hoverTimer: Timer?
    private var exitTimer: Timer?
    private var pointerInMenu = false
    private var pointerInAvatar = false
    private var cancellables: Set<AnyCancellable> = []
    private(set) var isVisible = false
    private var userHidden = false

    init(model: AppModel) {
        self.model = model
        let size = CGFloat(model.env.settings.get(Settings.avatarSize))
        panel = CompanionPanel(size: size)
        menuPanel = CompanionPanel(size: 10)
        super.init()
        hostView = AvatarHostView(model: model, controller: self)
        hostView.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = hostView
        let menu = NSHostingView(rootView: HoverMenuView(onSelect: { [weak self] s in self?.activate(s) },
                                                         onHover: { [weak self] inside in self?.menuHover(inside) }))
        menuPanel.contentView = menu
        menuPanel.setContentSize(menu.fittingSize)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.$refreshToken.sink { [weak self] _ in self?.refreshVisibility() }.store(in: &cancellables)
    }

    // MARK: Visibility

    func show() {
        userHidden = false
        applySize()
        restorePosition()
        refreshVisibility()
    }

    func toggleVisibility() { if isVisible { userHidden = true; hide() } else { show() } }

    func refreshVisibility() {
        if model.presentationMode || userHidden || !model.env.settings.get(Settings.onboardingComplete) { hide() }
        else if !isVisible { panel.orderFrontRegardless(); isVisible = true }
    }

    private func hide() { closeMenu(); panel.orderOut(nil); isVisible = false }

    func applySize() {
        let size = CGFloat(min(96, max(40, model.env.settings.get(Settings.avatarSize))))
        var f = panel.frame
        f.size = NSSize(width: size, height: size)
        panel.setFrame(f, display: true)
        hostView.frame = NSRect(origin: .zero, size: f.size)
    }

    // MARK: Position (per display, clamped, recoverable)

    private func screenKey(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
    }

    func restorePosition() {
        let positions = model.env.settings.get(Settings.avatarPositions)
        let screen = NSScreen.screens.first { positions[screenKey($0)] != nil } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let saved = positions[screenKey(screen)]
        let size = panel.frame.size
        let vf = screen.visibleFrame
        let origin = saved.map { NSPoint(x: $0[0], y: $0[1]) } ?? NSPoint(x: vf.maxX - size.width - 24, y: vf.midY)
        panel.setFrameOrigin(clamp(origin, size: size, to: vf))
    }

    func resetPosition() {
        var positions = model.env.settings.get(Settings.avatarPositions)
        positions.removeAll()
        model.env.settings.set(Settings.avatarPositions, positions)
        restorePosition()
    }

    func savePosition() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var positions = model.env.settings.get(Settings.avatarPositions)
        positions[screenKey(screen)] = [Double(panel.frame.origin.x), Double(panel.frame.origin.y)]
        model.env.settings.set(Settings.avatarPositions, positions)
    }

    /// Recover onto a connected display when a monitor disconnects.
    @objc private func screensChanged() {
        let f = panel.frame
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { restorePosition() }
        else if let s = panel.screen { panel.setFrameOrigin(clamp(f.origin, size: f.size, to: s.visibleFrame)) }
        closeMenu()
    }

    func clamp(_ p: NSPoint, size: NSSize, to vf: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, vf.minX), vf.maxX - size.width), y: min(max(p.y, vf.minY), vf.maxY - size.height))
    }

    func move(to origin: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: origin.x + panel.frame.width / 2, y: origin.y + panel.frame.height / 2)) }) ?? panel.screen else { return }
        panel.setFrameOrigin(clamp(origin, size: panel.frame.size, to: screen.visibleFrame))
    }

    /// Optional edge snapping after a drag.
    func snapToEdgeIfClose() {
        guard let vf = panel.screen?.visibleFrame else { return }
        var o = panel.frame.origin
        let threshold: CGFloat = 16
        if o.x - vf.minX < threshold { o.x = vf.minX + 4 }
        if vf.maxX - (o.x + panel.frame.width) < threshold { o.x = vf.maxX - panel.frame.width - 4 }
        panel.setFrameOrigin(o)
    }

    var frame: NSRect { panel.frame }

    // MARK: Hover menu (300 ms dwell, 400 ms exit grace, stable five actions)

    func avatarHover(_ inside: Bool, dragging: Bool) {
        pointerInAvatar = inside
        if inside {
            exitTimer?.invalidate()
            guard !dragging, !menuPanel.isVisible else { return }
            hoverTimer?.invalidate()
            let delay = Double(model.env.settings.get(Settings.hoverDelayMs)) / 1000
            hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.openMenu() }
            }
        } else {
            hoverTimer?.invalidate()
            scheduleClose()
        }
    }

    private func menuHover(_ inside: Bool) {
        pointerInMenu = inside
        if inside { exitTimer?.invalidate() } else { scheduleClose() }
    }

    private func scheduleClose() {
        exitTimer?.invalidate()
        let delay = Double(model.env.settings.get(Settings.hoverExitDelayMs)) / 1000
        exitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.pointerInMenu, !self.pointerInAvatar else { return }
                self.closeMenu()
            }
        }
    }

    func cancelHover() { hoverTimer?.invalidate(); closeMenu() }

    private func openMenu() {
        guard isVisible, let screen = panel.screen else { return }
        let vf = screen.visibleFrame
        let size = menuPanel.frame.size
        let a = panel.frame
        // Open toward the side with more space; overlap slightly so the pointer path is continuous.
        let rightSpace = vf.maxX - a.maxX, leftSpace = a.minX - vf.minX
        let x = rightSpace >= leftSpace ? a.maxX - 2 : a.minX - size.width + 2
        let y = a.midY - size.height / 2
        menuPanel.setFrameOrigin(clamp(NSPoint(x: x, y: y), size: size, to: vf))
        menuPanel.orderFrontRegardless()
    }

    func closeMenu() { menuPanel.orderOut(nil); pointerInMenu = false }

    private func activate(_ section: WorkspaceSection) {
        closeMenu()
        model.openWorkspace?(section)
    }

    func clicked() { closeMenu(); model.openWorkspace?(nil) }
}

/// Hosts the avatar, owns pointer handling: click vs drag (6 pt threshold),
/// file drops (adds references), context menu and accessibility.
final class AvatarHostView: NSView {
    private weak var controller: FloatingCompanionController?
    private let model: AppModel
    private var downScreenPoint: NSPoint?
    private var downOrigin: NSPoint?
    private var dragging = false
    private var tracking: NSTrackingArea?

    @MainActor
    init(model: AppModel, controller: FloatingCompanionController) {
        self.model = model
        self.controller = controller
        super.init(frame: .zero)
        let host = NSHostingView(rootView: AvatarContainer(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)])
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Companion. Press to open the workspace.")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the visible circle intercepts input; transparent corners pass through.
        let local = convert(point, from: superview)
        let r = min(bounds.width, bounds.height) / 2
        let d = hypot(local.x - bounds.midX, local.y - bounds.midY)
        return d <= r ? self : nil
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { controller?.avatarHover(true, dragging: dragging) } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { controller?.avatarHover(false, dragging: dragging) } }

    override func mouseDown(with event: NSEvent) {
        downScreenPoint = NSEvent.mouseLocation
        downOrigin = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downScreenPoint, let origin = downOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragging && hypot(dx, dy) > 6 {
            dragging = true                                      // >6 pt cancels click activation
            MainActor.assumeIsolated { controller?.cancelHover() }
        }
        guard dragging else { return }
        MainActor.assumeIsolated {
            guard !model.env.settings.get(Settings.avatarLocked) else { return }
            controller?.move(to: NSPoint(x: origin.x + dx, y: origin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            if dragging { controller?.snapToEdgeIfClose(); controller?.savePosition() }
            else { controller?.clicked() }
        }
        dragging = false
        downScreenPoint = nil
    }

    override func accessibilityPerformPress() -> Bool { MainActor.assumeIsolated { controller?.clicked() }; return true }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            controller?.cancelHover()
            let menu = NSMenu()
            func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
                let i = ClosureMenuItem(title: title, action: action); menu.addItem(i); return i
            }
            let appearance = NSMenu()
            for skin in SkinStore.shared.allSkins() {
                let i = ClosureMenuItem(title: skin.displayName) { [model] in model.env.settings.set(Settings.avatarSkin, skin.id); model.reload() }
                i.state = model.env.settings.get(Settings.avatarSkin) == skin.id ? .on : .off
                appearance.addItem(i)
            }
            appearance.addItem(.separator())
            appearance.addItem(ClosureMenuItem(title: "Import Image…") { [model] in SkinStore.shared.importSkin(model: model) })
            let sizeMenu = NSMenu()
            for s in [40.0, 56.0, 72.0, 96.0] {
                let i = ClosureMenuItem(title: "\(Int(s)) pt") { [weak controller, model] in
                    model.env.settings.set(Settings.avatarSize, s); controller?.applySize()
                }
                i.state = model.env.settings.get(Settings.avatarSize) == s ? .on : .off
                sizeMenu.addItem(i)
            }
            let ap = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: ""); ap.submenu = appearance; menu.addItem(ap)
            let sz = NSMenuItem(title: "Size", action: nil, keyEquivalent: ""); sz.submenu = sizeMenu; menu.addItem(sz)
            let lock = item(model.env.settings.get(Settings.avatarLocked) ? "Unlock Position" : "Lock Position") { [model] in
                model.env.settings.set(Settings.avatarLocked, !model.env.settings.get(Settings.avatarLocked))
            }
            lock.state = model.env.settings.get(Settings.avatarLocked) ? .on : .off
            _ = item("Reset Position") { [weak controller] in controller?.resetPosition() }
            menu.addItem(.separator())
            _ = item(model.isPaused ? "Resume" : "Pause") { [model] in model.togglePause() }
            _ = item("Hide") { [weak controller] in controller?.toggleVisibility() }
            _ = item("Presentation Mode") { [model, weak controller] in model.togglePresentationMode(); controller?.refreshVisibility() }
            menu.addItem(.separator())
            _ = item("Quit Companion") { NSApp.terminate(nil) }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    // MARK: Drag and drop → references, never copies

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .link }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        MainActor.assumeIsolated { model.addDroppedFiles(urls) }
        return true
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    convenience init(title: String, action: @escaping () -> Void) { self.init(title: title, handler: action) }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
