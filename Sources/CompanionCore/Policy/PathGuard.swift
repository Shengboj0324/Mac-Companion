import Foundation

/// Resolves paths and rejects escapes through `..`, symlinks or aliases (spec §15/§16).
public struct PathGuard: Sendable {
    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map { PathGuard.canonical($0) }
    }

    /// Fully resolved, standardized URL. For non-existent leaves the parent is resolved.
    public static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath()
        }
        let parent = standardized.deletingLastPathComponent()
        guard parent.path != standardized.path else { return standardized }
        return canonical(parent).appendingPathComponent(standardized.lastPathComponent)
    }

    public static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let a = url.standardizedFileURL.pathComponents
        let b = root.standardizedFileURL.pathComponents
        guard a.count >= b.count else { return false }
        return Array(a.prefix(b.count)) == b
    }

    public func containingRoot(_ url: URL) -> URL? {
        let c = PathGuard.canonical(url)
        return roots.first { PathGuard.isDescendant(c, of: $0) }
    }

    /// Validates that `url` (after resolving symlinks) is inside an approved root.
    @discardableResult
    public func validate(_ url: URL) throws -> URL {
        let raw = url.standardizedFileURL
        if raw.pathComponents.contains("..") { throw CompanionError.pathEscape(url.lastPathComponent) }
        let c = PathGuard.canonical(url)
        guard roots.contains(where: { PathGuard.isDescendant(c, of: $0) }) else {
            throw CompanionError.pathEscape(url.lastPathComponent)
        }
        return c
    }

    public static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
