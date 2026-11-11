import Foundation

/// Line-oriented streaming HTTP. Injectable so adapters are testable offline.
public protocol HTTPTransport: Sendable {
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init(timeout: TimeInterval = 120) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionError.malformedResponse("Not HTTP") }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionError.malformedResponse("Not HTTP") }
        return (data, http)
    }
}

/// Server-Sent Events parser fed with lines (from `AsyncBytes.lines`, which drops blank lines,
/// so an event is dispatched when its `data:` line arrives).
public struct SSEParser {
    public struct Event: Equatable { public var event: String?; public var data: String }
    private var currentEvent: String?
    public init() {}

    public mutating func feed(_ rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { currentEvent = nil; return nil }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") { currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces); return nil }
        if line.hasPrefix("data:") {
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let ev = Event(event: currentEvent, data: data)
            currentEvent = nil
            return ev
        }
        return nil
    }
}

enum ProviderHTTP {
    /// Maps HTTP status and body to a distinct, user-meaningful error kind.
    static func error(status: Int, body: String, provider: ProviderID) -> CompanionError {
        let lower = body.lowercased()
        let kind: ProviderErrorKind
        switch status {
        case 401, 403: kind = .invalidKey
        case 402: kind = .insufficientBalance
        case 404: kind = .unsupportedModel
        case 408: kind = .timeout
        case 429: kind = lower.contains("quota") || lower.contains("billing") || lower.contains("credit") ? .insufficientBalance : .rateLimited
        case 529, 503: kind = .overloaded
        case 400..<500:
            if lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist") || lower.contains("unsupported")) { kind = .unsupportedModel }
            else if lower.contains("credit") || lower.contains("balance") { kind = .insufficientBalance }
            else { kind = .badRequest }
        case 500...: kind = .server
        default: kind = .unknown
        }
        let message = (try? JSON.object(Data(body.utf8))).flatMap { obj -> String? in
            if let e = obj["error"] as? [String: Any] { return e["message"] as? String }
            return obj["message"] as? String
        } ?? ""
        return .provider(kind, Redactor.redact(String(message.prefix(300))))
    }

    static func collect(_ lines: AsyncThrowingStream<String, Error>, limit: Int = 64_000) async -> String {
        var out = ""
        do { for try await l in lines { out += l + "\n"; if out.count > limit { break } } } catch {}
        return out
    }

    static func validateHost(_ url: URL, provider: ProviderID) throws {
        guard url.scheme == "https", url.host == provider.allowedHost else {
            throw CompanionError.policyViolation("Endpoint not allowed for \(provider.displayName)")
        }
    }

    static func mapTransport(_ error: Error) -> Error {
        if error is CompanionError || error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorTimedOut { return CompanionError.provider(.timeout, "") }
            if ns.code == NSURLErrorCancelled { return CompanionError.cancelled }
            return CompanionError.provider(.network, "")
        }
        return CompanionError.provider(.unknown, "")
    }
}
