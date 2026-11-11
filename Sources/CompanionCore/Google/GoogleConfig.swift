import Foundation
import CryptoKit

/// Google access modes (spec §6). Selected-document mode is the default.
public enum GoogleAccessMode: String, Codable, CaseIterable, Sendable {
    case selectedDocuments, metadataDiscovery, broadReading

    public var scopes: [String] {
        let base = ["openid", "email", "https://www.googleapis.com/auth/drive.file"]
        switch self {
        case .selectedDocuments: return base
        case .metadataDiscovery: return base + ["https://www.googleapis.com/auth/drive.metadata.readonly"]
        case .broadReading: return base + ["https://www.googleapis.com/auth/drive.readonly"]
        }
    }

    public var explanation: String {
        switch self {
        case .selectedDocuments:
            return "Only documents you select or that Companion creates. Note: Google's drive.file scope also permits changes to those files — Companion's own policy keeps them read-only unless you approve an edit."
        case .metadataDiscovery:
            return "Also discover titles and folders (no document text). Titles can still be sensitive."
        case .broadReading:
            return "Search and index a larger part of your Drive. Folder filters are Companion restrictions, not Google-enforced limits. Requires Google verification for public release."
        }
    }
}

/// Developer OAuth configuration. A desktop client secret is not confidential and
/// is never treated as a security boundary; PKCE + state protect the flow.
public struct GoogleConfig: Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String?
    public var pickerURL: URL?

    public init(clientID: String, clientSecret: String? = nil, pickerURL: URL? = nil) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.pickerURL = pickerURL
    }

    public var isConfigured: Bool { !clientID.isEmpty && !clientID.hasPrefix("$(") && clientID.hasSuffix(".apps.googleusercontent.com") }

    /// Reads `GoogleOAuthClientID` / `GoogleOAuthClientSecret` / `GooglePickerURL` from Info.plist or environment.
    public static func fromBundle(_ bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> GoogleConfig {
        func value(_ key: String) -> String? {
            if let v = environment["COMPANION_" + key], !v.isEmpty { return v }
            if let v = bundle.object(forInfoDictionaryKey: key) as? String, !v.isEmpty, !v.hasPrefix("$(") { return v }
            return nil
        }
        return GoogleConfig(clientID: value("GoogleOAuthClientID") ?? "", clientSecret: value("GoogleOAuthClientSecret"),
                            pickerURL: value("GooglePickerURL").flatMap(URL.init(string:)))
    }

    public static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    public static let allowedHosts: Set<String> = ["oauth2.googleapis.com", "www.googleapis.com", "docs.googleapis.com", "accounts.google.com"]
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        verifier = PKCE.randomURLSafe(64)
        challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        state = PKCE.randomURLSafe(32)
    }

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = state
    }

    public static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    public func authorizationURL(config: GoogleConfig, redirectURI: String, scopes: [String], loginHint: String? = nil) -> URL {
        var c = URLComponents(url: GoogleConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        return c.url!
    }
}

/// Parses a pasted Docs/Drive link into a file ID. A link is a locator, not an access grant.
public enum GoogleLink {
    public static func fileID(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"/d/([A-Za-z0-9_-]{20,})"#, options: .regularExpression) {
            return String(s[r].dropFirst(3))
        }
        if let c = URLComponents(string: s), let id = c.queryItems?.first(where: { $0.name == "id" })?.value { return id }
        if s.range(of: #"^[A-Za-z0-9_-]{25,}$"#, options: .regularExpression) != nil { return s }
        return nil
    }
}
