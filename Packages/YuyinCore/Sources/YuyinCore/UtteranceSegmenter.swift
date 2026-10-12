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
    public var endpointBackstopMs = 8_000

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

/// Sentence segmentation with an energy VAD.
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
    /// End position and smoothed level of each frame still in `buffer` (soft cut points).
    private var frames: [(end: Int, level: Float)] = []

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

    /// Pause that closes the open sentence (longer while it is still short).
    public var requiredSilenceMs: Int {
        AudioSpec.milliseconds(forSamples: voicedSamples) < config.shortSentenceMs
            ? max(config.silenceMs, config.shortSentenceSilenceMs)
            : config.silenceMs
    }

    /// Whether a recognizer endpoint should close the open sentence now.
    public var acceptsEndpoint: Bool {
        // Speech the VAD missed entirely (very quiet) can only be closed by the recognizer.
        guard firstSpeech != nil else { return true }
        if openDurationMs >= config.endpointBackstopMs { return true }
        let isShort = AudioSpec.milliseconds(forSamples: voicedSamples) < config.shortSentenceMs
        return trailingSilenceMs >= (isShort ? requiredSilenceMs : config.endpointSilenceMs)
    }

    public var isEmpty: Bool { buffer.isEmpty }

    /// Feeds samples; returns sentences closed by silence or length.
    public mutating func push(_ samples: [Float]) -> [Segment] {
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
        frames.append((frameEnd, smoothed))

        if !inSpeech {
            onsetRun = smoothed > onsetThreshold && level > holdThreshold ? onsetRun + 1 : 0
            if onsetRun >= config.onsetFrames {
                // Speech began at the first of the loud frames.
                let onset = frameEnd - frameLength * config.onsetFrames
                inSpeech = true
                lastVoicedEnd = frameEnd
                voicedSamples = frameLength * config.onsetFrames
                onsetRun = 0
                if firstSpeech == nil { firstSpeech = max(bufferStart, onset) }
            }
        } else {
            // Inside a sentence: the smoothed level decides whether the pause continues;
            // the raw frame level keeps the end boundary precise.
            let holding = smoothed > holdThreshold
            if holding && level > holdThreshold {
                lastVoicedEnd = frameEnd
                voicedSamples += frameLength
            }
            if !holding, frameEnd - lastVoicedEnd >= AudioSpec.samples(forMilliseconds: requiredSilenceMs) {
                if voicedSamples >= AudioSpec.samples(forMilliseconds: config.minSpeechMs) {
                    let end = min(frameEnd, lastVoicedEnd + AudioSpec.samples(forMilliseconds: config.trailingPadMs))
                    return cut(at: end, reason: .silence)
                }
                // A click or a cough: not a sentence (its audio stays in the buffer).
                inSpeech = false
                voicedSamples = 0
            }
        }

        if frameEnd - bufferStart >= AudioSpec.samples(forMilliseconds: config.maxUtteranceMs) {
            return cut(at: softCutPoint(), reason: .maxLength)
        }
        return nil
    }

    /// End of the quietest frame in the last few seconds (not the very last 300 ms).
    private func softCutPoint() -> Int {
        // Never cut so early that the segment is only the leading silence.
        let windowStart = max(
            total - AudioSpec.samples(forMilliseconds: config.softCutWindowMs),
            bufferStart + AudioSpec.samples(forMilliseconds: config.maxUtteranceMs / 2)
        )
        let windowEnd = total - AudioSpec.samples(forMilliseconds: 300)
        var best: (end: Int, level: Float)?
        for frame in frames where frame.end > windowStart && frame.end <= windowEnd {
            if best == nil || frame.level < best!.level { best = frame }
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

        let segment = Segment(
            samples: Array(buffer[0..<(end - start)]),
            startSample: start,
            endSample: end,
            speechStartSample: speechFrom,
            speechEndSample: speechTo,
            speechMs: AudioSpec.milliseconds(forSamples: voicedSamples),
            reason: reason
        )

        dropBuffer(before: end)
        voicedSamples = 0
        if reason == .maxLength && inSpeech {
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
