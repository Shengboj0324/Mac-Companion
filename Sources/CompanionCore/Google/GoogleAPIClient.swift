import Foundation

/// Authorized JSON client for Drive/Docs with an endpoint allowlist, one token
/// refresh on 401, and bounded backoff for 429/5xx.
public final class GoogleAPIClient: @unchecked Sendable {
    private let auth: GoogleAuthService
    private let transport: HTTPTransport
    public var maxRetries = 3
    public var sleep: @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    public init(auth: GoogleAuthService, transport: HTTPTransport) { self.auth = auth; self.transport = transport }

    public enum APIError: Error, Equatable { case accessLost(Int), notFound, preconditionFailed(String), http(Int, String) }

    public func json(_ method: String, _ url: URL, accountID: UUID, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard url.scheme == "https", let host = url.host, GoogleConfig.allowedHosts.contains(host) else {
            throw CompanionError.policyViolation("Google endpoint not allowed")
        }
        var attempt = 0
        var refreshed = false
        while true {
            let token = try await auth.accessToken(for: accountID, forceRefresh: refreshed)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSON.data(body)
            }
            let (data, http): (Data, HTTPURLResponse)
            do { (data, http) = try await transport.data(for: req) }
            catch {
                if method != "GET" { throw CompanionError.outcomeUnknown("Network interrupted during a Google write") }
                if attempt < maxRetries { attempt += 1; await sleep(pow(2, Double(attempt))); continue }
                throw CompanionError.provider(.network, "")
            }
            switch http.statusCode {
            case 200..<300:
                return data.isEmpty ? [:] : ((try? JSON.object(data)) ?? [:])
            case 401 where !refreshed:
                refreshed = true; continue
            case 401: throw APIError.accessLost(401)
            case 403:
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("rateLimitExceeded") || text.contains("userRateLimitExceeded"), attempt < maxRetries {
                    attempt += 1; await sleep(pow(2, Double(attempt))); continue
                }
                throw APIError.accessLost(403)
            case 404: throw APIError.notFound
            case 400 where String(decoding: data, as: UTF8.self).contains("requiredRevisionId"),
                 409, 412:
                throw APIError.preconditionFailed("The document changed since it was reviewed")
            case 429, 500...:
                // Writes are never blindly retried: their outcome must be reconciled.
                if method == "GET", attempt < maxRetries { attempt += 1; await sleep(pow(2, Double(attempt))); continue }
                if method != "GET" { throw CompanionError.outcomeUnknown("Google returned \(http.statusCode) during a write") }
                throw APIError.http(http.statusCode, "")
            default:
                let message = ((try? JSON.object(data))?["error"] as? [String: Any])?["message"] as? String ?? ""
                throw APIError.http(http.statusCode, Redactor.redact(message))
            }
        }
    }
}

public struct DriveFile: Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var modifiedTime: Date?
    public var version: String?
    public var webViewLink: String?
    public var parents: [String]
    public var capabilities: [String: Bool]
    public var trashed: Bool
    public var appProperties: [String: String]

    static func parse(_ o: [String: Any]) -> DriveFile {
        DriveFile(id: o["id"] as? String ?? "", name: o["name"] as? String ?? "", mimeType: o["mimeType"] as? String ?? "",
                  modifiedTime: (o["modifiedTime"] as? String).flatMap(GoogleDates.parse), version: o["version"] as? String,
                  webViewLink: o["webViewLink"] as? String, parents: o["parents"] as? [String] ?? [],
                  capabilities: (o["capabilities"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool },
                  trashed: o["trashed"] as? Bool ?? false, appProperties: o["appProperties"] as? [String: String] ?? [:])
    }
}

enum GoogleDates {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Drive v3 + Docs v1 calls used by Companion.
public struct GoogleDrive: Sendable {
    let api: GoogleAPIClient
    static let fileFields = "id,name,mimeType,modifiedTime,version,webViewLink,parents,trashed,appProperties,capabilities(canEdit,canCopy,canComment)"

    public init(api: GoogleAPIClient) { self.api = api }

    public func file(_ id: String, accountID: UUID) async throws -> DriveFile {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        c.queryItems = [.init(name: "fields", value: Self.fileFields), .init(name: "supportsAllDrives", value: "true")]
        return DriveFile.parse(try await api.json("GET", c.url!, accountID: accountID))
    }

    public func startPageToken(accountID: UUID) async throws -> String {
        let o = try await api.json("GET", URL(string: "https://www.googleapis.com/drive/v3/changes/startPageToken?supportsAllDrives=true")!, accountID: accountID)
        guard let t = o["startPageToken"] as? String else { throw CompanionError.malformedResponse("No start page token") }
        return t
    }

    public struct ChangePage: Sendable { public var changes: [(fileID: String, removed: Bool, file: DriveFile?)]; public var next: String?; public var newStart: String? }

    public func changes(pageToken: String, accountID: UUID) async throws -> ChangePage {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")!
        c.queryItems = [.init(name: "pageToken", value: pageToken), .init(name: "pageSize", value: "200"),
                        .init(name: "includeItemsFromAllDrives", value: "true"), .init(name: "supportsAllDrives", value: "true"),
                        .init(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fileFields)))")]
        let o = try await api.json("GET", c.url!, accountID: accountID)
        let changes = (o["changes"] as? [[String: Any]] ?? []).map { ch in
            (fileID: ch["fileId"] as? String ?? "", removed: ch["removed"] as? Bool ?? false,
             file: (ch["file"] as? [String: Any]).map(DriveFile.parse))
        }
        return ChangePage(changes: changes, next: o["nextPageToken"] as? String, newStart: o["newStartPageToken"] as? String)
    }

    /// Finds app-created files by our action marker (for timeout reconciliation).
    public func findByMarker(_ marker: String, accountID: UUID) async throws -> [DriveFile] {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: "appProperties has { key='companionAction' and value='\(marker)' } and trashed=false"),
                        .init(name: "fields", value: "files(\(Self.fileFields))")]
        let o = try await api.json("GET", c.url!, accountID: accountID)
        return (o["files"] as? [[String: Any]] ?? []).map(DriveFile.parse)
    }

    public func createDocument(name: String, parent: String?, marker: String, accountID: UUID) async throws -> DriveFile {
        var body: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.document", "appProperties": ["companionAction": marker]]
        if let parent { body["parents"] = [parent] }
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?fields=\(Self.fileFields)&supportsAllDrives=true")!
        return DriveFile.parse(try await api.json("POST", url, accountID: accountID, body: body))
    }

    public func copy(fileID: String, name: String, parent: String?, marker: String, accountID: UUID) async throws -> DriveFile {
        var body: [String: Any] = ["name": name, "appProperties": ["companionAction": marker]]
        if let parent { body["parents"] = [parent] }
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)/copy?fields=\(Self.fileFields)&supportsAllDrives=true")!
        return DriveFile.parse(try await api.json("POST", url, accountID: accountID, body: body))
    }

    /// Visibility of a destination folder: "private", "shared (N)" or nil when it cannot be assessed.
    public func visibility(folderID: String, accountID: UUID) async -> String? {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(folderID)/permissions?fields=permissions(type,role)&supportsAllDrives=true")!
        guard let o = try? await api.json("GET", url, accountID: accountID), let perms = o["permissions"] as? [[String: Any]] else { return nil }
        if perms.contains(where: { ($0["type"] as? String) == "anyone" }) { return "anyone with the link" }
        let others = perms.filter { ($0["role"] as? String) != "owner" }
        return others.isEmpty ? "private" : "shared with \(others.count) other(s)"
    }

    public func document(_ id: String, accountID: UUID) async throws -> [String: Any] {
        let url = URL(string: "https://docs.googleapis.com/v1/documents/\(id)?includeTabsContent=true")!
        return try await api.json("GET", url, accountID: accountID)
    }

    public func batchUpdate(_ id: String, requests: [[String: Any]], requiredRevisionID: String, accountID: UUID) async throws -> [String: Any] {
        let url = URL(string: "https://docs.googleapis.com/v1/documents/\(id):batchUpdate")!
        return try await api.json("POST", url, accountID: accountID,
                                  body: ["requests": requests, "writeControl": ["requiredRevisionId": requiredRevisionID]])
    }
}
