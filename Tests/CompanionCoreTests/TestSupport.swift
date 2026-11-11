import Foundation
import XCTest
@testable import CompanionCore

/// Scripted HTTP transport for offline provider/Google tests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Response { var status: Int; var lines: [String]; var headers: [String: String] = [:] }
    private let lock = NSLock()
    var handler: (URLRequest) throws -> Response
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) throws -> Response = { _ in Response(status: 500, lines: []) }) { self.handler = handler }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        lock.withLock { requests.append(request) }
        let r = try handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (http, AsyncThrowingStream { c in r.lines.forEach { c.yield($0) }; c.finish() })
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let r = try handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (Data(r.lines.joined(separator: "\n").utf8), http)
    }

    var requestCount: Int { lock.withLock { requests.count } }
}

/// Scripted LLM provider: each call pops the next list of events.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    var scripts: [[ProviderEvent]]
    var failures: [Error] = []
    private(set) var received: [LLMRequest] = []

    init(id: ProviderID = .anthropic, scripts: [[ProviderEvent]]) { self.id = id; self.scripts = scripts }

    func stream(_ request: LLMRequest, apiKey: String) -> AsyncThrowingStream<ProviderEvent, Error> {
        let (events, failure): ([ProviderEvent], Error?) = lock.withLock {
            received.append(request)
            if !failures.isEmpty { return ([], failures.removeFirst()) }
            return (scripts.isEmpty ? [.textDelta("ok"), .usage(input: 10, output: 2), .completed(stopReason: "end_turn", requestID: "r")] : scripts.removeFirst(), nil)
        }
        return AsyncThrowingStream { c in
            if let failure { c.finish(throwing: failure); return }
            events.forEach { c.yield($0) }
            c.finish()
        }
    }
}

final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ text: String) -> URL {
        let u = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: u)
        return u
    }

    func mkdir(_ relative: String) -> URL {
        let u = url.appendingPathComponent(relative, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Fully wired environment with test doubles.
final class TestEnv {
    let temp = TempDir()
    let clock = ManualClock(Date())
    let secrets = InMemorySecretStore()
    let calendar = MockCalendarSource()
    let transport = MockTransport()
    let provider: ScriptedProvider
    let env: CompanionEnvironment
    let root: URL

    init(provider: ScriptedProvider = ScriptedProvider(scripts: []), stabilization: TimeInterval = 0,
         google: GoogleConfig = GoogleConfig(clientID: "test.apps.googleusercontent.com")) {
        self.provider = provider
        let paths = AppPaths(support: temp.url.appendingPathComponent("Support"), managedWorkspaces: temp.url.appendingPathComponent("Workspaces"))
        env = try! CompanionEnvironment(paths: paths, clock: clock, secrets: secrets, calendarSource: calendar, transport: transport,
                                        googleConfig: google, providerAdapters: [provider.id: provider])
        env.indexing.stabilizationSeconds = stabilization
        env.conversations.retryDelay = { _ in }
        env.googleAPI.sleep = { _ in }
        root = temp.mkdir("Root")
    }

    func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
}

extension XCTestCase {
    func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                                 file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) async {
        do { _ = try await expression(); XCTFail("Expected error. \(message)", file: file, line: line) }
        catch { handler(error) }
    }
}
