import Foundation
import CoreServices

/// FSEvents wrapper. Events are hints: callers still run periodic reconciliation
/// scans to repair anything missed (spec §5).
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "companion.fsevents")
    private let handler: @Sendable ([String]) -> Void
    private let latency: CFTimeInterval
    public private(set) var paths: [String] = []

    public init(latency: CFTimeInterval = 1.0, handler: @escaping @Sendable ([String]) -> Void) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func watch(_ paths: [String]) {
        stop()
        self.paths = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: NSArray.self)
            let changed = (cfArray as? [String]) ?? []
            if !changed.isEmpty { watcher.handler(Array(Set(changed.prefix(count)))) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                           kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
