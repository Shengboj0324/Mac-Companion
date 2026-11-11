import Foundation
import Compression

/// Minimal read-only ZIP reader (stored + deflate) for DOCX extraction. Bounded:
/// refuses entries whose uncompressed size exceeds `maxEntryBytes`.
public struct ZipReader {
    public struct Entry { public let name: String; let method: UInt16; let compressedSize: Int; let uncompressedSize: Int; let localHeaderOffset: Int }

    private let data: Data
    public let entries: [Entry]
    public let maxEntryBytes: Int

    public init(data: Data, maxEntryBytes: Int = 64 << 20) throws {
        self.data = data
        self.maxEntryBytes = maxEntryBytes
        self.entries = try ZipReader.readCentralDirectory(data)
    }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    public func extract(_ name: String) throws -> Data {
        guard let e = entry(named: name) else { throw CompanionError.notFound(name) }
        guard e.uncompressedSize <= maxEntryBytes else { throw CompanionError.unsupported("Entry too large") }
        let lh = e.localHeaderOffset
        guard lh + 30 <= data.count, data.u32(lh) == 0x04034b50 else { throw CompanionError.malformedResponse("Bad local header") }
        let nameLen = Int(data.u16(lh + 26)), extraLen = Int(data.u16(lh + 28))
        let start = lh + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.count else { throw CompanionError.malformedResponse("Truncated zip") }
        let payload = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0: return payload
        case 8: return try Self.inflate(payload, expected: e.uncompressedSize)
        default: throw CompanionError.unsupported("Zip compression method \(e.method)")
        }
    }

    static func inflate(_ input: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw CompanionError.malformedResponse("Inflate failed") }
        return output
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw CompanionError.malformedResponse("Not a zip") }
        var eocd = -1
        let lowest = max(0, data.count - 22 - 65_535)
        var i = data.count - 22
        while i >= lowest { if data.u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw CompanionError.malformedResponse("Missing end of central directory") }
        let count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x02014b50 else {
                throw CompanionError.malformedResponse("Bad central directory")
            }
            let method = data.u16(offset + 10)
            let csize = Int(data.u32(offset + 20)), usize = Int(data.u32(offset + 24))
            let nameLen = Int(data.u16(offset + 28)), extraLen = Int(data.u16(offset + 30)), commentLen = Int(data.u16(offset + 32))
            let local = Int(data.u32(offset + 42))
            guard offset + 46 + nameLen <= data.count else { throw CompanionError.malformedResponse("Bad name") }
            let name = String(decoding: data.subdata(in: (offset + 46)..<(offset + 46 + nameLen)), as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: local))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }
}

extension Data {
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
}
