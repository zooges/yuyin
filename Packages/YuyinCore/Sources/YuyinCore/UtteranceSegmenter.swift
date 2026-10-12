import Foundation

public struct SegmenterConfig: Equatable, Sendable {
    /// Trailing silence that closes a sentence.
    public var silenceMs = 700
    /// A sentence with less speech than this so far is usually unfinished ("他应该学的是…",
    /// "先来把一刀…"): it needs a longer pause to close, so the rest joins it instead of
    /// becoming a separate fragment that the corrector has to guess at.
    public var shortSentenceMs = 2_000
    public var shortSentenceSilenceMs = 1_300
    /// Continuous audio (videos, calls with background music) is cut at the quietest
    /// point of the last few seconds once a sentence reaches this length.
    public var maxUtteranceMs = 15_000
    /// How far back a length cut may look for a quiet point.
    public var softCutWindowMs = 3_000
    /// Audio kept after the last voiced frame.
    public var trailingPadMs = 200
    /// Voiced audio shorter than this is treated as noise.
    public var minSpeechMs = 250
    public var frameMs = 20
    /// Window over which the noise floor tracks the quiet frames.
    public var floorWindowMs = 3_000
    /// Absolute RMS below which a frame is never speech (about -48 dBFS).
    public var minThreshold: Float = 0.004
    /// Speech starts when the smoothed level exceeds the noise floor by this factor (~9.5 dB)…
    public var speechRatio: Float = 3
    /// …and continues while it stays above this lower factor (~8 dB), so quiet word endings
    /// and noise spikes inside pauses don't toggle the state (hysteresis).
    public var holdRatio: Float = 2.5
    /// Level smoothing window; short clicks and breaths inside pauses average out.
    public var smoothingMs = 100
    /// Consecutive loud frames needed to start a sentence.
    public var onsetFrames = 3
    /// The streaming recognizer's endpoint (it decoded nothing for a while) also fires in
    /// mid-sentence: a drawn-out syllable, game sounds or music under a short breath. It closes
    /// a sentence only once the VAD has heard at least this much pause as well…
    public var endpointSilenceMs = 400
    /// …unless the sentence is already this long (continuous audio where the VAD never pauses).
    /// Energy VAD only: a voice model does hear the pauses in continuous speech.
    public var endpointBackstopMs = 8_000
    /// With a voice model, a long sentence closes at a shorter pause (a breath between clauses)
    /// instead of running on to the length cut, which falls in the past and splits words there.
    public var longSentenceMs = 6_000
    public var longSentenceSilenceMs = 450
    public var veryLongSentenceMs = 10_000
    public var veryLongSentenceSilenceMs = 250
    /// A voice model reports speech only after hearing some of it; the sentence starts this much earlier.
    public var voiceOnsetMs = 200

    public init() {}

    public init(silenceMs: Int, maxUtteranceMs: Int) {
        self.silenceMs = silenceMs
        self.maxUtteranceMs = maxUtteranceMs
    }
}

/// One closed sentence. Sample indexes are absolute within the session.
public struct Segment: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case silence
        case maxLength
        /// Another voice took over without a pause (cut in the past, speech continues).
        case speakerChange
        case forced
    }

    public let samples: [Float]
    public let startSample: Int
    public let endSample: Int
    /// First / last voiced sample; equal to start/end when no speech was detected.
    public let speechStartSample: Int
    public let speechEndSample: Int
    public let speechMs: Int
    public let reason: Reason
}

extension Segment.Reason {
    /// Cut while someone is speaking, at a point in the past: the recognizer already heard
    /// the start of the next sentence.
    public var isInSpeech: Bool {
        self == .maxLength || self == .speakerChange
    }
}

/// Sentence segmentation with an energy VAD, or a voice model's decisions when available.
///
/// **Contiguous**: every segment spans from the previous cut to this one, so no audio the
/// recognizer heard is ever left out — the VAD only chooses *where* to cut. (An earlier
/// version dropped audio the VAD judged silent; with continuous program audio such as a
/// video with music the VAD misjudged everything as noise and most speech was lost.)
/// Leading silence is dropped only on request (`discardIdle`), when the caller also knows
/// the recognizer heard nothing.
///
/// Pure value type: deterministic for a given input regardless of chunk sizes.
public struct UtteranceSegmenter: Sendable {
    public let config: SegmenterConfig

    private let frameLength: Int
    private var noiseFloor: Float
    private var recentLevels: [Float] = []
    private var recentIndex = 0
    private var smoothing: [Float] = []
    private var onsetRun = 0
    private var pendingFrame: [Float] = []
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var total = 0
    /// End position, smoothed level and voice-model verdict of each frame still in `buffer`
    /// (soft cut points).
    private var frames: [(end: Int, level: Float, speech: Bool)] = []

    /// Where the recognizer wrote a comma or full stop (absolute samples): a length cut goes
    /// near one rather than at any quiet frame.
    private var clauseEnds: [Int] = []

    /// Speech is decided by a voice model's decisions (`push(_:voice:)`), not by level.
    public private(set) var usesVoiceModel = false
    private var voiceQueue: [VoiceDecision] = []
    private var voiceSpeech = false

    private var inSpeech = false
    private var lastVoicedEnd = 0
    private var voicedSamples = 0
    /// First voiced sample in the current (uncut) audio, if the VAD heard speech.
    private var firstSpeech: Int?

    public init(config: SegmenterConfig = SegmenterConfig()) {
        self.config = config
        frameLength = AudioSpec.samples(forMilliseconds: config.frameMs)
        noiseFloor = config.minThreshold / config.speechRatio
    }

    /// Absolute index of the next sample to be pushed.
    public var position: Int { total }

    /// Where the open sentence's audio begins (the previous cut).
    public var openStart: Int { bufferStart }

    /// First voiced sample of the open sentence, if speech has started.
    public var openSpeechStart: Int? { firstSpeech }

    public var hasSpeech: Bool { inSpeech && voicedSamples > 0 }

    /// Pause since the VAD last heard a voiced frame in the open sentence.
    public var trailingSilenceMs: Int {
        guard firstSpeech != nil else { return AudioSpec.milliseconds(forSamples: total - bufferStart) }
        return AudioSpec.milliseconds(forSamples: total - lastVoicedEnd)
    }

    /// Length of the open sentence so far.
    public var openDurationMs: Int {
        AudioSpec.milliseconds(forSamples: total - (firstSpeech ?? bufferStart))
    }

    /// Pause that closes the open sentence: longer while it is still short; with a voice
    /// model, shorter once it is long.
    public var requiredSilenceMs: Int {
        if AudioSpec.milliseconds(forSamples: voicedSamples) < config.shortSentenceMs {
            return max(config.silenceMs, config.shortSentenceSilenceMs)
        }
        guard usesVoiceModel else { return config.silenceMs }
        if openDurationMs >= config.veryLongSentenceMs { return min(config.silenceMs, config.veryLongSentenceSilenceMs) }
        if openDurationMs >= config.longSentenceMs { return min(config.silenceMs, config.longSentenceSilenceMs) }
        return config.silenceMs
    }

    /// Whether a recognizer endpoint should close the open sentence now.
    public var acceptsEndpoint: Bool {
        // Speech the VAD missed entirely (very quiet) can only be closed by the recognizer.
        guard firstSpeech != nil else { return true }
        if !usesVoiceModel, openDurationMs >= config.endpointBackstopMs { return true }
        let isShort = AudioSpec.milliseconds(forSamples: voicedSamples) < config.shortSentenceMs
        return trailingSilenceMs >= (isShort ? requiredSilenceMs : min(config.endpointSilenceMs, requiredSilenceMs))
    }

    public var isEmpty: Bool { buffer.isEmpty }

    /// From now on speech is what the voice model says; every `push` must then carry the
    /// decisions for its samples.
    public mutating func useVoiceModel() {
        usesVoiceModel = true
    }

    /// Feeds samples; returns sentences closed by silence or length. `voice` holds the voice
    /// model's decisions for windows completed by these samples (ignored without `useVoiceModel()`).
    public mutating func push(_ samples: [Float], voice: [VoiceDecision] = []) -> [Segment] {
        if usesVoiceModel { voiceQueue.append(contentsOf: voice) }
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        var closed: [Segment] = []

        var cursor = samples.startIndex
        while cursor < samples.endIndex {
            let need = frameLength - pendingFrame.count
            let take = min(need, samples.endIndex - cursor)
            pendingFrame.append(contentsOf: samples[cursor..<(cursor + take)])
            cursor += take
            total += take
            if pendingFrame.count == frameLength {
                if let segment = processFrame(endingAt: total) {
                    closed.append(segment)
                }
                pendingFrame.removeAll(keepingCapacity: true)
            }
        }
        return closed
    }

    /// Closes the open sentence now (engine endpoint, pause, stop). Keeps everything.
    public mutating func cut() -> Segment? {
        cut(at: total, reason: .forced)
    }

    /// Audio of the open sentence from `absolute` on (clamped to what is still buffered).
    public func samples(from absolute: Int) -> [Float] {
        let from = min(max(absolute, bufferStart), total)
        return Array(buffer[(from - bufferStart)...])
    }

    /// Clause marks of the recognizer (absolute samples), for the next length cut.
    public mutating func noteClauseEnds(_ marks: [Int]) {
        clauseEnds = marks.filter { $0 > bufferStart }
    }

    /// Closes the open sentence in mid-speech near `sample` (a speaker change):
    /// at the frame within `reachMs` the voice model heard no speech in, else the quietest.
    /// Speech continues into the next sentence.
    public mutating func cutInSpeech(near sample: Int, reason: Segment.Reason, reachMs: Int = 300) -> Segment? {
        guard inSpeech else { return nil }
        let reach = AudioSpec.samples(forMilliseconds: reachMs)
        var best: (end: Int, level: Float, speech: Bool)?
        for frame in frames where abs(frame.end - sample) <= reach && frame.end > bufferStart && frame.end < total {
            guard let current = best else { best = frame; continue }
            if (current.speech && !frame.speech) || (current.speech == frame.speech && frame.level < current.level) {
                best = frame
            }
        }
        return cut(at: best?.end ?? sample, reason: reason)
    }

    /// Drops leading audio older than `keepingMs` while nobody is speaking. Call only when
    /// the recognizer has heard nothing either, so a VAD mistake can never discard speech.
    public mutating func discardIdle(keepingMs: Int) {
        guard !inSpeech else { return }
        let keep = AudioSpec.samples(forMilliseconds: keepingMs)
        if total - bufferStart > keep {
            dropBuffer(before: total - keep)
            firstSpeech = nil
        }
    }

    // MARK: - Private

    private var onsetThreshold: Float {
        max(config.minThreshold, noiseFloor * config.speechRatio)
    }

    private var holdThreshold: Float {
        max(config.minThreshold * config.holdRatio / config.speechRatio, noiseFloor * config.holdRatio)
    }

    private mutating func processFrame(endingAt frameEnd: Int) -> Segment? {
        let level = AudioSpec.rms(pendingFrame[...])
        let smoothed = smooth(level)
        updateNoiseFloor(level: smoothed)
        let modelSpeech = usesVoiceModel ? voiceVerdict(at: frameEnd) : nil
        frames.append((frameEnd, smoothed, modelSpeech ?? false))

        if let speech = modelSpeech {
            if !inSpeech {
                if speech {
                    startSpeech(at: frameEnd - frameLength - AudioSpec.samples(forMilliseconds: config.voiceOnsetMs),
                                frameEnd: frameEnd, voiced: frameLength)
                }
            } else if speech {
                lastVoicedEnd = frameEnd
                voicedSamples += frameLength
            } else if let segment = closeIfPaused(at: frameEnd) {
                return segment
            }
        } else if !inSpeech {
            onsetRun = smoothed > onsetThreshold && level > holdThreshold ? onsetRun + 1 : 0
            if onsetRun >= config.onsetFrames {
                // Speech began at the first of the loud frames.
                startSpeech(at: frameEnd - frameLength * config.onsetFrames,
                            frameEnd: frameEnd, voiced: frameLength * config.onsetFrames)
                onsetRun = 0
            }
        } else {
            // Inside a sentence: the smoothed level decides whether the pause continues;
            // the raw frame level keeps the end boundary precise.
            let holding = smoothed > holdThreshold
            if holding && level > holdThreshold {
                lastVoicedEnd = frameEnd
                voicedSamples += frameLength
            }
            if !holding, let segment = closeIfPaused(at: frameEnd) {
                return segment
            }
        }

        if frameEnd - bufferStart >= AudioSpec.samples(forMilliseconds: config.maxUtteranceMs) {
            return cut(at: softCutPoint(), reason: .maxLength)
        }
        return nil
    }

    private mutating func startSpeech(at onset: Int, frameEnd: Int, voiced: Int) {
        inSpeech = true
        lastVoicedEnd = frameEnd
        voicedSamples = voiced
        if firstSpeech == nil { firstSpeech = max(bufferStart, onset) }
    }

    /// Inside a pause: closes the sentence once the pause is long enough.
    private mutating func closeIfPaused(at frameEnd: Int) -> Segment? {
        guard frameEnd - lastVoicedEnd >= AudioSpec.samples(forMilliseconds: requiredSilenceMs) else { return nil }
        if voicedSamples >= AudioSpec.samples(forMilliseconds: config.minSpeechMs) {
            let end = min(frameEnd, lastVoicedEnd + AudioSpec.samples(forMilliseconds: config.trailingPadMs))
            return cut(at: end, reason: .silence)
        }
        // A click or a cough: not a sentence (its audio stays in the buffer).
        inSpeech = false
        voicedSamples = 0
        return nil
    }

    /// The latest decision whose window ends by `frameEnd`. Later decisions are never used
    /// even when already known, so the result doesn't depend on how audio was chunked.
    private mutating func voiceVerdict(at frameEnd: Int) -> Bool {
        var used = 0
        for decision in voiceQueue {
            guard decision.endSample <= frameEnd else { break }
            voiceSpeech = decision.isSpeech
            used += 1
        }
        if used > 0 { voiceQueue.removeFirst(used) }
        return voiceSpeech
    }

    /// End of the quietest frame in the last few seconds (not the very last 300 ms),
    /// preferring frames the voice model heard no speech in — and, when the recognizer wrote a
    /// comma there, frames just around it (-150…+300 ms): splitting the user's monologue at
    /// clause marks changed the corrected text least (7% vs up to 9% at fixed offsets).
    private func softCutPoint() -> Int {
        // Never cut so early that the segment is only the leading silence.
        var windowStart = max(
            total - AudioSpec.samples(forMilliseconds: config.softCutWindowMs),
            bufferStart + AudioSpec.samples(forMilliseconds: config.maxUtteranceMs / 2)
        )
        var windowEnd = total - AudioSpec.samples(forMilliseconds: 300)
        if let mark = clauseEnds.last(where: { $0 > windowStart && $0 <= windowEnd }) {
            windowStart = max(windowStart, mark - AudioSpec.samples(forMilliseconds: 150))
            windowEnd = min(windowEnd, mark + AudioSpec.samples(forMilliseconds: 300))
        }
        var best: (end: Int, level: Float, speech: Bool)?
        for frame in frames where frame.end > windowStart && frame.end <= windowEnd {
            guard let current = best else { best = frame; continue }
            if (current.speech && !frame.speech) || (current.speech == frame.speech && frame.level < current.level) {
                best = frame
            }
        }
        return best?.end ?? total
    }

    private mutating func smooth(_ level: Float) -> Float {
        let window = max(1, config.smoothingMs / config.frameMs)
        smoothing.append(level)
        if smoothing.count > window { smoothing.removeFirst(smoothing.count - window) }
        return smoothing.reduce(0, +) / Float(smoothing.count)
    }

    /// Low-percentile statistics: the floor follows the quiet part of the last few seconds,
    /// so steady background noise (fans, hum) stops counting as speech, while the natural
    /// dips between syllables keep speech above the floor. The first 1.5 s calibrates
    /// quickly; inside a sentence the floor rises slowly so long sustained speech survives.
    private mutating func updateNoiseFloor(level: Float) {
        let windowFrames = max(1, config.floorWindowMs / config.frameMs)
        if recentLevels.count < windowFrames {
            recentLevels.append(level)
        } else {
            recentLevels[recentIndex] = level
            recentIndex = (recentIndex + 1) % windowFrames
        }
        let sorted = recentLevels.sorted()
        let target = max(1e-5, sorted.isEmpty ? level : sorted[Int(Double(sorted.count - 1) * 0.2)])
        let calibrating = recentLevels.count * config.frameMs < 1500
        let rate: Float
        if target < noiseFloor || calibrating {
            rate = 0.2
        } else {
            rate = inSpeech ? 0.01 : 0.02
        }
        noiseFloor += (target - noiseFloor) * rate
    }

    private mutating func cut(at requestedEnd: Int, reason: Segment.Reason) -> Segment? {
        let end = min(max(requestedEnd, bufferStart), total)
        guard end > bufferStart, !buffer.isEmpty else { return nil }
        let start = bufferStart
        let speechFrom = firstSpeech.map { min(max($0, start), end) } ?? start
        let speechTo = firstSpeech != nil ? min(max(lastVoicedEnd, speechFrom), end) : end
        let continues = reason.isInSpeech && inSpeech
        // Speech the voice model heard after a cut in the past belongs to the next sentence.
        let carried = continues && usesVoiceModel ? frames.filter { $0.end > end && $0.speech }.count * frameLength : 0

        let segment = Segment(
            samples: Array(buffer[0..<(end - start)]),
            startSample: start,
            endSample: end,
            speechStartSample: speechFrom,
            speechEndSample: speechTo,
            speechMs: AudioSpec.milliseconds(forSamples: max(0, voicedSamples - carried)),
            reason: reason
        )

        dropBuffer(before: end)
        clauseEnds.removeAll { $0 <= end }
        voicedSamples = carried
        if continues {
            // Speech continues straight into the next sentence.
            firstSpeech = end
            lastVoicedEnd = max(lastVoicedEnd, end)
        } else {
            inSpeech = false
            firstSpeech = nil
        }
        return segment
    }

    private mutating func dropBuffer(before absolute: Int) {
        let count = min(buffer.count, absolute - bufferStart)
        guard count > 0 else { return }
        buffer.removeFirst(count)
        bufferStart += count
        frames.removeAll { $0.end <= bufferStart }
    }
}
