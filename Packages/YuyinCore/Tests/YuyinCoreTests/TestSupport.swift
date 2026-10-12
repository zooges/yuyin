import Foundation
@testable import YuyinCore

enum Signal {
    static func tone(ms: Int, amplitude: Float = 0.2, frequency: Float = 220) -> [Float] {
        let n = AudioSpec.samples(forMilliseconds: ms)
        return (0..<n).map { i in amplitude * sin(Float(i) * 2 * .pi * frequency / Float(AudioSpec.sampleRate)) }
    }

    /// Speech-like: a tone whose loudness rises and falls ~4 times a second (syllables),
    /// never fully silent within the burst.
    static func speech(ms: Int, amplitude: Float = 0.2) -> [Float] {
        let n = AudioSpec.samples(forMilliseconds: ms)
        let rate = Float(AudioSpec.sampleRate)
        return (0..<n).map { i in
            let t = Float(i) / rate
            let envelope = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
            return amplitude * envelope * sin(2 * .pi * 220 * t)
        }
    }

    static func silence(ms: Int, noise: Float = 0.0005) -> [Float] {
        let n = AudioSpec.samples(forMilliseconds: ms)
        var seed: UInt32 = 12345
        return (0..<n).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed % 2000) / 1000 - 1) * noise
        }
    }

    static func chunks(_ samples: [Float], size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map {
            Array(samples[$0..<min($0 + size, samples.count)])
        }
    }
}

/// Emits one character per voiced chunk; mimics a streaming recognizer.
final class ScriptedStreaming: StreamingASREngine, @unchecked Sendable {
    let providerID = "test-stream"
    private let lock = NSLock()
    private var text = ""
    /// Fires a single engine endpoint once the open sentence reaches this many characters.
    var endpointAfterChars: Int?
    /// Reports an endpoint with empty text on every chunk (like sherpa's silence rule).
    var silenceEndpoints = false
    /// Chunks of speech before any text is produced (decoder latency).
    var textDelayChunks = 0
    /// Writes "，" after every this many characters, reporting when (like X-ASR's punctuation).
    var clauseEveryChars: Int?
    private var voicedChunks = 0
    private var samplesSinceReset = 0
    private var clauseEnds: [Double] = []
    /// When each character of `text` was written (seconds since the last reset).
    private var times: [Double] = []
    var prepareError: Error?
    var prepareDelayNanos: UInt64 = 0
    private(set) var shutdownCount = 0

    func prepare() async throws {
        if prepareDelayNanos > 0 { try? await Task.sleep(nanoseconds: prepareDelayNanos) }
        if let prepareError { throw prepareError }
    }

    func accept(_ samples: [Float]) async throws -> StreamingUpdate {
        lock.withLock {
            samplesSinceReset += samples.count
            if AudioSpec.peak(samples) > 0.05 {
                voicedChunks += 1
                let now = Double(samplesSinceReset) / Double(AudioSpec.sampleRate)
                if voicedChunks > textDelayChunks {
                    text += "字"
                    times.append(now)
                }
                if let every = clauseEveryChars, text.filter({ $0 == "字" }).count % every == 0, text.last == "字" {
                    text += "，"
                    times.append(now)
                    clauseEnds.append(now)
                }
            }
            var endpoint = silenceEndpoints && text.isEmpty
            if let limit = endpointAfterChars, text.count >= limit {
                endpoint = true
                endpointAfterChars = nil
            }
            return StreamingUpdate(text: text, isEndpoint: endpoint, clauseEnds: clauseEnds, heardUntil: times.last)
        }
    }

    func finishUtterance() async -> String {
        lock.withLock {
            let out = text
            text = ""
            voicedChunks = 0
            samplesSinceReset = 0
            clauseEnds = []
            times = []
            return out
        }
    }

    func finishUtterance(keepingUntil seconds: Double) async -> String {
        let kept = lock.withLock { String(zip(text, times).prefix { $0.1 < seconds }.map(\.0)) }
        _ = await finishUtterance()
        return kept
    }

    func shutdown() async {
        lock.withLock { shutdownCount += 1 }
    }
}

final class ScriptedCorrector: CorrectorASREngine, @unchecked Sendable {
    let providerID: String
    private let lock = NSLock()
    var delayNanos: UInt64 = 0
    var error: Error?
    var output: ((String) -> String)?
    private(set) var calls = 0
    private(set) var maxConcurrent = 0
    private var running = 0

    init(id: String = "test-correct") {
        providerID = id
    }

    func prepare() async throws {}

    func correct(_ samples: [Float], hint: String) async throws -> String {
        lock.withLock {
            calls += 1
            running += 1
            maxConcurrent = max(maxConcurrent, running)
        }
        defer { lock.withLock { running -= 1 } }
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if let error { throw error }
        return output?(hint) ?? "纠\(hint)。"
    }

    func shutdown() async {}
}

struct StaticProvider: EngineProvider {
    let set: EngineSet
    func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
}

actor EventLog {
    private(set) var events: [TranscriptEvent] = []

    func append(_ e: TranscriptEvent) { events.append(e) }

    var phases: [SessionPhase] {
        events.compactMap { if case .phase(let p) = $0 { return p } else { return nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let n) = $0 { return n } else { return nil } }
    }

    var removals: Int {
        events.filter { if case .remove = $0 { return true } else { return false } }.count
    }

    static func collect(_ session: TranscriptionSession) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let task = Task {
            for await e in session.events { await log.append(e) }
        }
        return (log, task)
    }
}

extension TranscriptionSession {
    func feed(_ samples: [Float], chunk: Int = 1024) async {
        for c in Signal.chunks(samples, size: chunk) {
            await ingest(c)
        }
    }
}

/// Tells "speakers" apart by pitch: below 330 Hz is speaker 0, above is speaker 1.
final class PitchSpeakerLabeler: SpeakerLabeling, @unchecked Sendable {
    func prepare(expectedSpeakers: Int) async throws {}

    func assign(_ samples: [Float], speechMs: Int) async throws -> Int? {
        Self.pitch(samples) < 330 ? 0 : 1
    }

    func embed(_ samples: [Float]) async -> [Float]? {
        Self.pitch(samples) < 330 ? [1, 0] : [0, 1]
    }

    func shutdown() async {}

    /// From the median half-period of the loud parts (background noise crosses zero constantly).
    static func pitch(_ samples: [Float]) -> Float {
        let crossings = samples.indices.dropFirst().filter { (samples[$0 - 1] < 0) != (samples[$0] < 0) }
        let halves = zip(crossings, crossings.dropFirst())
            .filter { a, b in samples[a..<b].contains { abs($0) > 0.05 } }
            .map { $1 - $0 }
            .sorted()
        guard !halves.isEmpty else { return 0 }
        return Float(AudioSpec.sampleRate) / Float(2 * halves[halves.count / 2])
    }
}

/// Speech wherever a 512-sample window is louder than 0.05 (stands in for Silero).
final class LevelVoiceDetector: VoiceActivityDetecting, @unchecked Sendable {
    private var pending: [Float] = []
    private var position = 0

    func prepare() async throws {}

    func detect(_ samples: [Float]) async -> [VoiceDecision] {
        pending += samples
        var out: [VoiceDecision] = []
        while pending.count >= 512 {
            let window = Array(pending.prefix(512))
            pending.removeFirst(512)
            position += 512
            out.append(VoiceDecision(endSample: position, isSpeech: AudioSpec.peak(window) > 0.05))
        }
        return out
    }

    func shutdown() async {}
}
