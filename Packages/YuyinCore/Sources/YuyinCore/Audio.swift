import Foundation

/// Every engine in Yuyin consumes 16 kHz mono Float32 PCM in [-1, 1].
public enum AudioSpec {
    public static let sampleRate = 16_000

    public static func milliseconds(forSamples samples: Int) -> Int {
        Int((Int64(samples) * 1000) / Int64(sampleRate))
    }

    public static func samples(forMilliseconds ms: Int) -> Int {
        Int((Int64(ms) * Int64(sampleRate)) / 1000)
    }

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func peak(_ samples: [Float]) -> Float {
        var m: Float = 0
        for s in samples { m = max(m, abs(s)) }
        return m
    }

    /// Brings a quiet sentence up to a normal speech level before recognition (laptop mics
    /// often record at −40 dBFS). The level is taken from the loudest 30 % of 20 ms frames so
    /// pauses don't inflate the gain; the gain is capped and never clips.
    public static func normalizedForRecognition(_ samples: [Float], targetRMS: Float = 0.08, maxGain: Float = 12) -> [Float] {
        guard samples.count >= 320 else { return samples }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / 320 + 1)
        for start in stride(from: 0, to: samples.count, by: 320) {
            levels.append(rms(samples[start..<min(start + 320, samples.count)]))
        }
        levels.sort()
        let loud = levels[(levels.count * 7 / 10)...]
        let speech = loud.reduce(0, +) / Float(loud.count)
        let top = peak(samples)
        guard speech > 1e-5, top > 0 else { return samples }
        let gain = min(maxGain, targetRMS / speech, 0.95 / top)
        return gain > 1.05 ? samples.map { $0 * gain } : samples
    }

    /// Little-endian 16-bit PCM, clipped.
    public static func int16Data(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            }
        }
        return data
    }
}

/// Receives every sample the session ingests (e.g. to keep a recording on disk).
public protocol SessionAudioSink: AnyObject, Sendable {
    func append(_ samples: [Float])
    func close()
}

/// Streams 16 kHz mono 16-bit PCM to a WAV file. The header is finalized on `close()`;
/// `WAVFile.read` tolerates an unfinalized header so a crashed session is still readable.
public final class WAVFileWriter: SessionAudioSink, @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var dataBytes: UInt32 = 0
    private var closed = false

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: url.path, contents: WAVFile.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = AudioSpec.int16Data(samples)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        try? handle.write(contentsOf: data)
        dataBytes &+= UInt32(data.count)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: WAVFile.header(dataBytes: dataBytes))
        try? handle.close()
    }

    deinit { close() }
}

public enum WAVFile {
    static func header(dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(AudioSpec.sampleRate)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    /// In-memory WAV (used for cloud upload of a single utterance).
    public static func encode(_ samples: [Float]) -> Data {
        let pcm = AudioSpec.int16Data(samples)
        return header(dataBytes: UInt32(pcm.count)) + pcm
    }

    /// Reads a 16-bit mono WAV written by `WAVFileWriter`, optionally a sample range.
    public static func read(_ url: URL, range: Range<Int>? = nil) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let headerSize = 44
        let fileSize = Int(try handle.seekToEnd())
        let total = max(0, (fileSize - headerSize) / 2)
        let lower = max(0, min(total, range?.lowerBound ?? 0))
        let upper = max(lower, min(total, range?.upperBound ?? total))
        try handle.seek(toOffset: UInt64(headerSize + lower * 2))
        let data = try handle.read(upToCount: (upper - lower) * 2) ?? Data()
        let scale = 1 / Float(Int16.max)
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) * scale }
        }
    }
}
