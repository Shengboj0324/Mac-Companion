import Foundation
import Network

/// One-shot loopback HTTP receiver for the installed-app OAuth redirect
/// (http://127.0.0.1:<port>). Accepts exactly one callback, validates `state`.
public final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "companion.oauth.loopback")
    private var continuation: CheckedContinuation<String, Error>?
    private let expectedState: String
    private let lock = NSLock()
    public private(set) var port: UInt16 = 0

    public init(expectedState: String) { self.expectedState = expectedState }

    public var redirectURI: String { "http://127.0.0.1:\(port)" }

    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    self?.port = listener.port?.rawValue ?? 0
                    cont.resume()
                case .failed(let e):
                    guard once.claim() else { return }
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the authorization code (or throws on error/cancel/timeout).
    public func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.withLock { self.continuation = cont }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CompanionError.google("Sign-in timed out")
            }
            defer { group.cancelAll(); self.stop() }
            return try await group.next()!
        }
    }

    public func cancel() { finish(.failure(CompanionError.cancelled)) }

    public func stop() { listener?.cancel(); listener = nil }

    private func finish(_ result: Result<String, Error>) {
        let c: CheckedContinuation<String, Error>? = lock.withLock { let c = continuation; continuation = nil; return c }
        c?.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            guard let result = Self.parse(request: request, expectedState: self.expectedState) else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(notFound.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let body: String
            switch result {
            case .success: body = "<html><body style='font-family:-apple-system;padding:40px'><h2>Companion is connected.</h2><p>You can close this tab and return to Companion.</p></body></html>"
            case .failure(let e): body = "<html><body style='font-family:-apple-system;padding:40px'><h2>Sign-in did not complete.</h2><p>\(e.localizedDescription)</p></body></html>"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.finish(result)
        }
    }

    /// Returns nil for unrelated requests (favicon, malformed), which are ignored.
    static func parse(request: String, expectedState: String) -> Result<String, Error>? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        if comps.path != "/" && comps.path != "" { return nil }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let err = q["error"] {
            return .failure(err == "access_denied" ? CompanionError.cancelled : CompanionError.google("Authorization error: \(err)"))
        }
        guard q["state"] == expectedState else { return .failure(CompanionError.google("State mismatch — sign-in rejected")) }
        guard let code = q["code"], !code.isEmpty else { return .failure(CompanionError.google("No authorization code")) }
        return .success(code)
    }
}

/// Thread-safe one-shot flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
