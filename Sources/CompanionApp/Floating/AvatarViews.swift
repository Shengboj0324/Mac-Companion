import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import CompanionCore

struct AvatarContainer: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let skinID = model.env.settings.get(Settings.avatarSkin)
        let reduce = model.env.settings.get(Settings.reduceMotion) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        AvatarView(state: model.avatarState, skin: SkinStore.shared.skin(id: skinID), reduceMotion: reduce)
            .id(model.refreshToken)
    }
}

/// Minimal circle with restrained status colour plus a shape cue, or an
/// original built-in character, or a validated imported image. Appearance never
/// changes permissions or model behaviour.
struct AvatarView: View {
    let state: AvatarState
    let skin: Skin
    let reduceMotion: Bool
    @State private var spin = false

    var tint: Color {
        switch state {
        case .idle: return Color(nsColor: .systemTeal)
        case .working: return Color(nsColor: .systemBlue)
        case .attention: return Color(nsColor: .systemOrange)
        case .paused: return Color(nsColor: .systemGray)
        case .awaitingApproval: return Color(nsColor: .systemPurple)
        }
    }

    var glyph: String {
        switch state {
        case .idle: return "circle.fill"
        case .working: return "ellipsis"
        case .attention: return "exclamationmark"
        case .paused: return "pause.fill"
        case .awaitingApproval: return "checklist"
        }
    }

    var stateLabel: String {
        switch state {
        case .idle: return "Ready"
        case .working: return "Working"
        case .attention: return "Something is ready"
        case .paused: return "Paused"
        case .awaitingApproval: return "Awaiting your approval"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                switch skin.kind {
                case .circle:
                    Circle().fill(.regularMaterial)
                    Circle().strokeBorder(tint, lineWidth: max(2, d * 0.06))
                    Image(systemName: glyph).font(.system(size: d * 0.3, weight: .semibold)).foregroundStyle(tint)
                case .mochi:
                    MochiCharacter(state: state, tint: tint)
                case .image(let image):
                    Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
                    Circle().strokeBorder(tint, lineWidth: max(2, d * 0.05))
                case .sprite(let sheet):
                    SpriteView(sheet: sheet, row: state == .working ? 1 : (state == .attention || state == .awaitingApproval) ? 2 : 0,
                               animate: !reduceMotion && state == .working)
                        .clipShape(Circle())
                    Circle().strokeBorder(tint, lineWidth: max(2, d * 0.05))
                }
                if state == .working && !reduceMotion {
                    // Brief animation only while work is actually occurring.
                    Circle().trim(from: 0, to: 0.25).stroke(tint, style: StrokeStyle(lineWidth: max(2, d * 0.06), lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                }
                if state == .paused || state == .awaitingApproval, skin.kind != .circle {
                    Image(systemName: glyph).font(.system(size: d * 0.18, weight: .bold)).foregroundStyle(.white)
                        .padding(d * 0.06).background(Circle().fill(tint)).offset(x: d * 0.32, y: -d * 0.32)
                }
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Companion — \(stateLabel)")
        .help("Companion — \(stateLabel). Hover for actions, click to open, drag to move, drop files to add references.")
    }
}

/// Original built-in character ("Mochi"), drawn with vector shapes.
struct MochiCharacter: View {
    let state: AvatarState
    let tint: Color
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.9), Color(red: 1, green: 0.84, blue: 0.82)],
                                             startPoint: .top, endPoint: .bottom))
                // Hair fringe
                Ellipse().fill(Color(red: 0.25, green: 0.2, blue: 0.35)).frame(width: d * 0.95, height: d * 0.5).offset(y: -d * 0.3)
                    .clipShape(Circle().offset(y: d * 0.0).scale(1))
                HStack(spacing: d * 0.18) {
                    eye(d); eye(d)
                }.offset(y: d * 0.05)
                HStack(spacing: d * 0.42) {
                    Circle().fill(Color.pink.opacity(0.35)).frame(width: d * 0.12)
                    Circle().fill(Color.pink.opacity(0.35)).frame(width: d * 0.12)
                }.offset(y: d * 0.2)
                mouth(d).offset(y: d * 0.27)
                Circle().strokeBorder(tint, lineWidth: max(2, d * 0.05))
            }
            .clipShape(Circle())
        }
    }

    @ViewBuilder func eye(_ d: CGFloat) -> some View {
        if state == .paused {
            Capsule().fill(Color(red: 0.2, green: 0.15, blue: 0.3)).frame(width: d * 0.16, height: d * 0.035)
        } else {
            ZStack {
                Ellipse().fill(Color(red: 0.2, green: 0.15, blue: 0.3)).frame(width: d * 0.15, height: d * 0.2)
                Circle().fill(.white).frame(width: d * 0.05).offset(x: d * 0.025, y: -d * 0.04)
            }
        }
    }

    @ViewBuilder func mouth(_ d: CGFloat) -> some View {
        switch state {
        case .attention, .awaitingApproval: Circle().fill(Color(red: 0.6, green: 0.2, blue: 0.3)).frame(width: d * 0.07)
        default: Capsule().fill(Color(red: 0.6, green: 0.2, blue: 0.3)).frame(width: d * 0.12, height: d * 0.03)
        }
    }
}

struct SpriteView: View {
    let sheet: SpriteSheet
    let row: Int
    let animate: Bool
    @State private var frame = 0
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let w = sheet.image.size.width / CGFloat(sheet.columns)
            let h = sheet.image.size.height / CGFloat(sheet.rows)
            let r = min(row, sheet.rows - 1)
            Image(nsImage: sheet.image).resizable()
                .frame(width: g.size.width * CGFloat(sheet.columns), height: g.size.height * CGFloat(sheet.rows))
                .offset(x: -g.size.width * CGFloat(frame), y: -g.size.height * CGFloat(r))
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .clipped()
                .accessibilityHidden(true)
            let _ = (w, h)
        }
        .onReceive(timer) { _ in if animate { frame = (frame + 1) % sheet.columns } else if frame != 0 { frame = 0 } }
    }
}

/// Five stable hover actions; positions never change with AI suggestions.
struct HoverMenuView: View {
    let onSelect: (WorkspaceSection) -> Void
    let onHover: (Bool) -> Void
    private let items: [(WorkspaceSection, String)] = [(.ask, "Ask"), (.find, "Find files"), (.continueWork, "Continue"), (.today, "Today"), (.organize, "Organize")]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.0) { section, title in
                Button { onSelect(section) } label: {
                    Label(title, systemImage: section.symbol).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
                .accessibilityLabel(title)
            }
        }
        .padding(6)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .onHover(perform: onHover)
    }
}

struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || configuration.isPressed ? Color.accentColor.opacity(0.18) : .clear))
            .onHover { hovering = $0 }
    }
}

// MARK: Skins (data-only: images + bounded animation metadata)

struct SpriteSheet { let image: NSImage; let columns: Int; let rows: Int }

struct Skin: Identifiable {
    enum Kind: Equatable {
        case circle, mochi, image(NSImage), sprite(SpriteSheet)
        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) { case (.circle, .circle), (.mochi, .mochi): return true; default: return false }
        }
    }
    let id: String
    let displayName: String
    let kind: Kind
}

@MainActor
final class SkinStore {
    static let shared = SkinStore()
    private var cache: [String: Skin] = [:]
    static let maxBytes = 5 << 20
    static let maxDimension: CGFloat = 4096

    var directory: URL { AppPaths.standard().support.appendingPathComponent("Skins", isDirectory: true) }

    func allSkins() -> [Skin] {
        var skins = [Skin(id: "circle", displayName: "Circle", kind: .circle), Skin(id: "mochi", displayName: "Mochi (character)", kind: .mochi)]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "png" { if let s = load(f) { skins.append(s) } }
        return skins
    }

    func skin(id: String) -> Skin {
        if id == "mochi" { return Skin(id: id, displayName: "Mochi", kind: .mochi) }
        if id == "circle" { return Skin(id: id, displayName: "Circle", kind: .circle) }
        if let c = cache[id] { return c }
        if let s = load(directory.appendingPathComponent(id)) { cache[id] = s; return s }
        return Skin(id: "circle", displayName: "Circle", kind: .circle)
    }

    private func load(_ url: URL) -> Skin? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let metaURL = url.deletingPathExtension().appendingPathExtension("json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(SpriteMeta.self, from: data), meta.isValid {
            return Skin(id: url.lastPathComponent, displayName: url.deletingPathExtension().lastPathComponent,
                        kind: .sprite(SpriteSheet(image: image, columns: meta.columns, rows: meta.rows)))
        }
        return Skin(id: url.lastPathComponent, displayName: url.deletingPathExtension().lastPathComponent, kind: .image(image))
    }

    struct SpriteMeta: Codable {
        let columns: Int, rows: Int
        var isValid: Bool { (1...12).contains(columns) && (1...3).contains(rows) }
    }

    /// Imports a PNG/JPEG, validates size, and re-encodes it as a plain PNG
    /// (strips metadata; no scripts, URLs or executables can survive).
    func importSkin(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "Choose a square image, or a sprite sheet with rows for idle, working and attention."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxBytes else { throw CompanionError.invalidArgument("Image is larger than 5 MB") }
            guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)),
                  CGFloat(rep.pixelsWide) <= Self.maxDimension, CGFloat(rep.pixelsHigh) <= Self.maxDimension,
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw CompanionError.invalidArgument("Not a valid image")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "skin-\(UUID().uuidString.prefix(8)).png"
            try png.write(to: directory.appendingPathComponent(name))
            // Wider-than-tall images are treated as sprite sheets (3 rows when tall enough).
            let ratio = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
            if ratio >= 1.5 {
                let rows = rep.pixelsHigh >= rep.pixelsWide / 4 ? 3 : 1
                let columns = max(1, min(12, Int((ratio * Double(rows)).rounded())))
                let meta = SpriteMeta(columns: columns, rows: rows)
                try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent(name).deletingPathExtension().appendingPathExtension("json"))
            }
            model.env.settings.set(Settings.avatarSkin, name)
            model.reload()
        } catch {
            model.banner = error.localizedDescription
        }
    }
}
