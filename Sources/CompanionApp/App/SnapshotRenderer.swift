import AppKit
import SwiftUI
import CompanionCore

/// Development aid: `Companion --render-snapshots <dir>` renders key screens
/// offscreen (against a throwaway environment with sample data) and exits.
/// Used by scripts/snapshot.sh for visual review without screen-recording access.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-snapshots"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("companion-snap-\(UUID().uuidString)")
            let env = try CompanionEnvironment(paths: AppPaths(support: tmp.appendingPathComponent("S"), managedWorkspaces: tmp.appendingPathComponent("W")),
                                               secrets: InMemorySecretStore(), calendarSource: MockCalendarSource(), inMemoryDatabase: true)
            try seed(env, folder: tmp.appendingPathComponent("Docs"))
            let model = AppModel(env: env)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                for section in WorkspaceSection.allCases {
                    model.section = section
                    render(WorkspaceView(model: model), size: NSSize(width: 980, height: 660), appearance: appearance,
                           to: out.appendingPathComponent("workspace-\(section.rawValue)-\(suffix).png"))
                }
                render(OnboardingView(model: model, finish: {}), size: NSSize(width: 620, height: 520), appearance: appearance,
                       to: out.appendingPathComponent("onboarding-\(suffix).png"))
                render(HoverMenuView(onSelect: { _ in }, onHover: { _ in }).padding(10), size: NSSize(width: 180, height: 200), appearance: appearance,
                       to: out.appendingPathComponent("hover-menu-\(suffix).png"))
                let states: [AvatarState] = [.idle, .working, .attention, .paused, .awaitingApproval]
                let row = HStack(spacing: 16) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                        VStack(spacing: 8) {
                            AvatarView(state: s, skin: Skin(id: "circle", displayName: "", kind: .circle), reduceMotion: true).frame(width: 56, height: 56)
                            AvatarView(state: s, skin: Skin(id: "mochi", displayName: "", kind: .mochi), reduceMotion: true).frame(width: 56, height: 56)
                        }
                    }
                }.padding(16)
                render(row, size: NSSize(width: 400, height: 160), appearance: appearance, to: out.appendingPathComponent("avatars-\(suffix).png"))
                if let run = env.executor.pendingProposals().first {
                    render(PlanReviewView(model: model, run: run), size: NSSize(width: 680, height: 520), appearance: appearance,
                           to: out.appendingPathComponent("plan-review-\(suffix).png"))
                }
            }
            print("Snapshots written to \(out.path)")
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
        }
        return true
    }

    static func seed(_ env: CompanionEnvironment, folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("Research/Readings"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Research/Drafts"), withIntermediateDirectories: true)
        try "# Introduction\nSign language translation needs grammar-aware models.".write(to: folder.appendingPathComponent("Research/Drafts/Lit review draft.md"), atomically: true, encoding: .utf8)
        try "Evaluation methods compared across studies.".write(to: folder.appendingPathComponent("Research/Readings/evaluation notes.txt"), atomically: true, encoding: .utf8)
        try "Practice problems".write(to: folder.appendingPathComponent("Practice.txt"), atomically: true, encoding: .utf8)
        let root = try env.indexing.addRoot(folder)
        env.indexing.stabilizationSeconds = 0
        env.indexing.scan(root); env.indexing.processPending()
        let p = try env.projects.create(name: "Literature review")
        for a in env.indexing.assets() { try env.projects.addItem(projectID: p.id, kind: .file, targetID: a.id) }
        try env.projects.saveCheckpoint(projectID: p.id, note: "Finished the introduction", nextStep: "Compare evaluation approaches")
        let task = try env.tasks.create(title: "Rough draft", projectID: p.id, proposedDeadline: Date().addingTimeInterval(5 * 86_400), evidence: "Calendar event")
        _ = try env.tasks.extractRequirements(taskID: task.id, from: "Include an introduction. Use 12-point font, double-spaced. Submit the Google Doc link. Optional: add a visual.")
        _ = try env.memory.add(MemoryRecord(projectID: p.id, kind: .preference, statement: "Source readings stay separate from drafts",
                                            provenance: .userConfirmed, observedAt: Date()))
        _ = try env.memory.add(MemoryRecord(projectID: p.id, kind: .projectFact, statement: "Fluent Deaf readers have not evaluated the output yet",
                                            provenance: .sourcedObservation, observedAt: Date()))
        _ = try env.filing.learn()
        if let practice = env.indexing.assets().first(where: { $0.name == "Practice.txt" }) {
            let plan = ActionPlan(title: "Move Practice.txt to Research/Readings", operations: [
                PlannedOperation(kind: .move, sourcePath: practice.path, sourceHash: practice.contentHash,
                                 destinationPath: folder.appendingPathComponent("Research/Readings/Practice.txt").path, reason: "Similar files are kept there")],
                                  initiator: "user", createdAt: Date())
            try env.executor.propose(plan)
        }
    }

    static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
