import Foundation

/// Default exclusions: app bundles, credentials, dependency directories, VCS
/// internals and Companion's own managed output (spec §5).
public struct IgnoreRules: Sendable {
    public var managedDirectories: [String]

    public static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", "Pods", ".build", "DerivedData", "build",
        ".venv", "venv", "__pycache__", ".tox", ".gradle", ".idea", ".cache", "Carthage",
        ".Trash", ".ssh", ".aws", ".gnupg", ".kube", ".docker",
    ]

    /// Bundles that are never traversed or indexed.
    public static let ignoredBundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "xpc", "appex", "photoslibrary",
        "musiclibrary", "tvlibrary", "xcodeproj", "xcworkspace", "playground", "dSYM", "lproj",
    ]

    /// Package documents: visible as metadata-only assets, never traversed.
    public static let packageDocumentExtensions: Set<String> = [
        "pages", "numbers", "key", "rtfd", "scriv", "sketch", "graffle",
    ]

    public static let credentialNames: Set<String> = [
        ".env", ".netrc", ".npmrc", ".pypirc", "id_rsa", "id_ed25519", "id_ecdsa",
        "credentials", "credentials.json", "client_secret.json", "service-account.json",
        "keychain-db", ".git-credentials",
    ]

    public static let credentialExtensions: Set<String> = [
        "pem", "p12", "pfx", "keystore", "jks", "kdbx", "keychain", "ovpn", "mobileprovision",
    ]

    public init(managedDirectories: [String] = []) { self.managedDirectories = managedDirectories }

    public func shouldSkipDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        if Self.skippedDirectories.contains(name) { return true }
        if Self.ignoredBundleExtensions.contains(url.pathExtension) { return true }
        let path = url.standardizedFileURL.path
        return managedDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func shouldSkipFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        if name.hasPrefix("~$") { return true }                 // Office lock files
        if Self.credentialNames.contains(name.lowercased()) { return true }
        let ext = url.pathExtension.lowercased()
        if Self.credentialExtensions.contains(ext) { return true }
        if ["crdownload", "download", "part", "partial", "tmp", "swp"].contains(ext) { return true }
        return false
    }

    public func isPackageDocument(_ url: URL) -> Bool {
        Self.packageDocumentExtensions.contains(url.pathExtension.lowercased())
    }
}
