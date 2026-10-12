import Foundation
import YuyinBZip2

public enum ArchiveError: Error, LocalizedError, Equatable {
    case corrupt(String)
    case truncated
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let detail): return "模型压缩包损坏：\(detail)"
        case .truncated: return "模型压缩包不完整，请重新下载"
        case .unsafePath(let path): return "压缩包包含不安全路径：\(path)"
        }
    }
}

/// Streams a `.tar.bz2` to disk with constant memory (1 MB buffers), so a 1.7 GB
/// FireRed archive extracts on an iPhone. Rejects absolute paths and `..`; skips links.
public enum TarBz2Extractor {
    public static func extract(
        archive: URL,
        to directory: URL,
        isCancelled: () -> Bool = { false },
        progress: ((Double) -> Void)? = nil
    ) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let totalBytes = max(1, Int((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 1))

        guard let stream = yuyin_bz2_open() else { throw ArchiveError.corrupt("bzip2 初始化失败") }
        defer { yuyin_bz2_close(stream) }

        var parser = TarStreamParser(destination: directory)
        let chunkSize = 1 << 20
        var out = [UInt8](repeating: 0, count: chunkSize)
        var readBytes = 0
        var streamEnded = false

        /// One decoder call; returns (consumed, produced, status) after feeding output to the parser.
        func step(_ input: UnsafePointer<UInt8>?, _ count: Int) throws -> (Int, Int, Int32) {
            var consumed = 0
            var produced = 0
            let status = out.withUnsafeMutableBufferPointer { o in
                yuyin_bz2_decompress(stream, input, count, &consumed, o.baseAddress, o.count, &produced)
            }
            if status < 0 { throw ArchiveError.corrupt("bzip2 数据错误") }
            if produced > 0 {
                try out.withUnsafeBytes { try parser.feed(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) }
            }
            return (consumed, produced, status)
        }

        while !parser.isFinished {
            if isCancelled() { throw CancellationError() }
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            readBytes += chunk.count

            if chunk.isEmpty {
                // EOF: drain whatever the decoder still buffers.
                while !streamEnded && !parser.isFinished {
                    let (_, produced, status) = try step(nil, 0)
                    if status == 1 { streamEnded = true } else if produced == 0 { throw ArchiveError.truncated }
                }
                break
            }

            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                var offset = 0
                while offset < chunk.count && !parser.isFinished {
                    if streamEnded {
                        // Concatenated stream (pbzip2).
                        guard yuyin_bz2_reset(stream) == 0 else { throw ArchiveError.corrupt("bzip2 重置失败") }
                        streamEnded = false
                    }
                    let (consumed, produced, status) = try step(base + offset, chunk.count - offset)
                    offset += consumed
                    if status == 1 {
                        streamEnded = true
                    } else if consumed == 0 && produced == 0 {
                        throw ArchiveError.corrupt("bzip2 无进展")
                    }
                }
            }
            progress?(min(1, Double(readBytes) / Double(totalBytes)))
        }
        try parser.finish()
    }
}

/// Incremental ustar / GNU / pax parser writing regular files and directories.
struct TarStreamParser {
    private enum State {
        case header
        case body(remaining: Int, padding: Int, sink: Sink)
        case padding(Int)
    }

    private enum Sink {
        case file(FileHandle)
        case metadata(kind: UInt8)
        case discard
    }

    let destination: URL
    private var state: State = .header
    private var headerBuffer: [UInt8] = []
    private var metadata = Data()
    private var pendingLongName: String?
    private var zeroBlocks = 0
    private(set) var isFinished = false

    init(destination: URL) {
        self.destination = destination
        headerBuffer.reserveCapacity(512)
    }

    mutating func feed(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count, !isFinished {
            switch state {
            case .header:
                let take = min(512 - headerBuffer.count, bytes.count - offset)
                headerBuffer.append(contentsOf: bytes[offset..<(offset + take)])
                offset += take
                if headerBuffer.count == 512 {
                    try handleHeader()
                    headerBuffer.removeAll(keepingCapacity: true)
                }

            case .body(let remaining, let padding, let sink):
                let take = min(remaining, bytes.count - offset)
                let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + take)])
                switch sink {
                case .file(let handle):
                    try handle.write(contentsOf: Data(slice))
                case .metadata:
                    metadata.append(contentsOf: slice)
                case .discard:
                    break
                }
                offset += take
                if remaining - take == 0 {
                    try finishEntry(sink)
                    state = padding > 0 ? .padding(padding) : .header
                } else {
                    state = .body(remaining: remaining - take, padding: padding, sink: sink)
                }

            case .padding(let remaining):
                let take = min(remaining, bytes.count - offset)
                offset += take
                state = remaining - take == 0 ? .header : .padding(remaining - take)
            }
        }
    }

    func finish() throws {
        switch state {
        case .header where headerBuffer.isEmpty:
            return
        default:
            if !isFinished { throw ArchiveError.truncated }
        }
    }

    // MARK: - Private

    private mutating func handleHeader() throws {
        if headerBuffer.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks >= 2 { isFinished = true }
            return
        }
        zeroBlocks = 0

        let size = try Self.parseSize(Array(headerBuffer[124..<136]))
        let type = headerBuffer[156]
        let padding = (512 - size % 512) % 512

        var name = Self.string(headerBuffer[0..<100])
        if Self.string(headerBuffer[257..<262]) == "ustar" {
            let prefix = Self.string(headerBuffer[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        if let long = pendingLongName {
            name = long
            pendingLongName = nil
        }

        let sink: Sink
        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "x"):
            metadata.removeAll(keepingCapacity: true)
            sink = .metadata(kind: type)
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            if let target = try Self.safeURL(for: name, in: destination) {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: target.path, contents: nil)
                sink = .file(try FileHandle(forWritingTo: target))
            } else {
                sink = .discard
            }
        case UInt8(ascii: "5"):
            if let target = try Self.safeURL(for: name, in: destination) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            sink = .discard
        default:
            // Hard/sym links, devices, global pax headers: not needed for model bundles.
            sink = .discard
        }

        if size == 0 {
            try finishEntry(sink)
            state = .header
        } else {
            state = .body(remaining: size, padding: padding, sink: sink)
        }
    }

    private mutating func finishEntry(_ sink: Sink) throws {
        switch sink {
        case .file(let handle):
            try handle.close()
        case .metadata(let kind):
            if kind == UInt8(ascii: "L") {
                pendingLongName = String(decoding: metadata, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            } else {
                pendingLongName = Self.paxPath(metadata) ?? pendingLongName
            }
        case .discard:
            break
        }
    }

    static func parseSize(_ field: [UInt8]) throws -> Int {
        if let first = field.first, first & 0x80 != 0 {
            // Base-256 (GNU) for very large entries.
            var value = Int(first & 0x7F)
            for b in field.dropFirst() {
                guard value < (1 << 47) else { throw ArchiveError.corrupt("条目过大") }
                value = value << 8 | Int(b)
            }
            return value
        }
        let text = string(field[...]).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int(text, radix: 8), value >= 0, value < (1 << 40) else {
            throw ArchiveError.corrupt("无效的条目大小")
        }
        return value
    }

    static func paxPath(_ data: Data) -> String? {
        // Records: "<len> <key>=<value>\n"
        let text = String(decoding: data, as: UTF8.self)
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let kv = record[record.index(after: space)...]
            if kv.hasPrefix("path=") { return String(kv.dropFirst(5)) }
        }
        return nil
    }

    /// nil for entries that should be skipped (macOS resource forks).
    static func safeURL(for path: String, in root: URL) throws -> URL? {
        guard !path.hasPrefix("/") else { throw ArchiveError.unsafePath(path) }
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        if parts.contains("..") { throw ArchiveError.unsafePath(path) }
        if parts.contains("__MACOSX") || parts.last?.hasPrefix("._") == true { return nil }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }
}
