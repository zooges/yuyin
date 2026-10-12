import Foundation

/// Incremental cosine clustering of speaker embeddings (one per sentence).
///
/// Short clips give noisy embeddings (same-speaker similarity drops to ~0.2–0.45 below ~0.5 s
/// of speech, measured on real recordings), so only confident clips may start a new speaker;
/// short ones join the nearest existing speaker or stay unknown. Centroids are duration-weighted.
public struct OnlineSpeakerClusterer: Sendable {
    /// Similarity to a centroid needed to join it.
    public var threshold: Float
    /// Below this much speech a clip can't create a speaker.
    public var minNewSpeakerMs: Int
    /// A short clip still joins its nearest speaker above this similarity.
    public var shortClipThreshold: Float
    /// 0 = unlimited; otherwise new embeddings join the nearest cluster once full.
    public var maxSpeakers: Int
    /// Clips shorter than `fullClipMs` join at a lower similarity, down to `threshold - shortClipRelief`
    /// at `minNewSpeakerMs`: the same person's 2 s sentences rarely reach the threshold.
    public var shortClipRelief: Float
    public var fullClipMs: Int
    private var sums: [[Float]] = []

    /// Defaults measured with CAM++ (zh/en) on two AMI meetings and the user's recordings.
    public init(threshold: Float = 0.5, minNewSpeakerMs: Int = 2000, shortClipThreshold: Float = 0.35,
                maxSpeakers: Int = 0, shortClipRelief: Float = 0.1, fullClipMs: Int = 4000) {
        self.threshold = threshold
        self.minNewSpeakerMs = minNewSpeakerMs
        self.shortClipThreshold = shortClipThreshold
        self.maxSpeakers = maxSpeakers
        self.shortClipRelief = shortClipRelief
        self.fullClipMs = fullClipMs
    }

    /// Similarity a clip of this length needs to join a known speaker.
    public func joinThreshold(speechMs: Int) -> Float {
        guard speechMs < fullClipMs, fullClipMs > minNewSpeakerMs else { return threshold }
        let shortness = Float(fullClipMs - max(speechMs, minNewSpeakerMs)) / Float(fullClipMs - minNewSpeakerMs)
        return threshold - shortClipRelief * shortness
    }

    public var speakerCount: Int { sums.count }

    public mutating func assign(_ embedding: [Float], speechMs: Int = .max) -> Int? {
        guard let unit = Self.normalized(embedding) else { return nil }
        var best: Int?
        var bestScore: Float = -2
        for (i, sum) in sums.enumerated() {
            guard let centroid = Self.normalized(sum), centroid.count == unit.count else { continue }
            let score = zip(centroid, unit).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            if score > bestScore {
                bestScore = score
                best = i
            }
        }
        let confident = speechMs >= minNewSpeakerMs
        let full = maxSpeakers > 0 && sums.count >= maxSpeakers
        let weight = Float(max(1, min(speechMs, 10_000))) / 1000

        if let best {
            let joins = bestScore >= joinThreshold(speechMs: speechMs) || full || (!confident && bestScore >= shortClipThreshold)
            if joins {
                for j in sums[best].indices { sums[best][j] += unit[j] * weight }
                return best
            }
            // Too short to tell, and not like anyone known.
            if !confident { return nil }
        }
        sums.append(unit.map { $0 * weight })
        return sums.count - 1
    }

    static func normalized(_ v: [Float]) -> [Float]? {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { $0 / norm }
    }
}

/// Carrying speaker names over when sentences get new speaker numbers.
public enum SpeakerMapping {}

/// User edits to speaker labels: names, merges and per-sentence corrections.
/// Applied on top of what the clusterer produced, during or after a recording.
public struct SpeakerBook: Equatable, Sendable {
    public private(set) var names: [Int: String]
    /// Merged speaker → surviving speaker.
    private var aliases: [Int: Int] = [:]
    /// Sentence → speaker, set by the user.
    private var overrides: [UUID: Int] = [:]

    public init(names: [Int: String] = [:]) {
        self.names = names
    }

    public static func defaultLabel(_ index: Int) -> String {
        "说话人 \(index + 1)"
    }

    public func canonical(_ index: Int) -> Int {
        var current = index
        var seen: Set<Int> = []
        while let next = aliases[current], seen.insert(current).inserted {
            current = next
        }
        return current
    }

    public func label(for index: Int?) -> String? {
        guard let index else { return nil }
        let id = canonical(index)
        return names[id] ?? Self.defaultLabel(id)
    }

    public func resolve(_ utterance: Utterance) -> Utterance {
        var u = utterance
        if let forced = overrides[u.id] {
            u.speakerIndex = forced
        }
        u.speakerIndex = u.speakerIndex.map(canonical)
        return u
    }

    /// Names a speaker. Giving it the name of another speaker merges the two;
    /// returns the index that survives. An empty name restores the default label.
    @discardableResult
    public mutating func rename(_ index: Int, to name: String) -> Int {
        let id = canonical(index)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            names[id] = nil
            return id
        }
        if let existing = names.first(where: { $0.value == trimmed && $0.key != id })?.key {
            aliases[id] = existing
            names[id] = nil
            return existing
        }
        names[id] = trimmed
        return id
    }

    public mutating func reassign(_ id: UUID, to index: Int) {
        overrides[id] = canonical(index)
    }

    /// A fresh index for "new speaker".
    public func nextIndex(after utterances: [Utterance]) -> Int {
        let used = utterances.compactMap(\.speakerIndex) + Array(names.keys) + Array(aliases.keys) + Array(overrides.values)
        return (used.max() ?? -1) + 1
    }

    /// Speakers present in `utterances`, in order of first appearance.
    /// One pass without sorting the transcript: views ask for this on every live update.
    public func speakers(in utterances: [Utterance]) -> [Int] {
        // Speaker → (start, position) of its earliest sentence; ties keep array order.
        var first: [Int: (startMs: Int, position: Int)] = [:]
        for (position, u) in utterances.enumerated() {
            guard let i = resolve(u).speakerIndex else { continue }
            if let known = first[i], known.startMs <= u.startMs { continue }
            first[i] = (u.startMs, position)
        }
        return first.sorted { ($0.value.startMs, $0.value.position) < ($1.value.startMs, $1.value.position) }.map(\.key)
    }
}

extension SpeakerMapping {
    /// After re-diarization, carry user-given names over to the new speaker indexes
    /// (each new speaker takes the name of the old speaker most of its sentences had).
    public static func transferNames(
        _ names: [Int: String],
        from old: [Utterance],
        to map: [UUID: Int?]
    ) -> [Int: String] {
        guard !names.isEmpty else { return [:] }
        var votes: [Int: [Int: Int]] = [:]
        for u in old {
            guard let previous = u.speakerIndex, let mapped = map[u.id], let next = mapped else { continue }
            votes[next, default: [:]][previous, default: 0] += 1
        }
        var result: [Int: String] = [:]
        var used: Set<String> = []
        for next in votes.keys.sorted() {
            guard let winner = votes[next]?.max(by: { $0.value < $1.value })?.key,
                  let name = names[winner], !used.contains(name)
            else { continue }
            result[next] = name
            used.insert(name)
        }
        return result
    }
}

/// Finds where another voice takes over inside one sentence. People in a heated discussion
/// answer without a pause, so the pause-based segmenter puts several speakers in one sentence
/// and the whole sentence gets one label. Each window (1.5 s, every 0.5 s) is compared with the
/// sentence so far; two windows in a row that sound like someone else mark a change in the
/// middle of the first. On two AMI meetings this raised speaker accuracy from 93.3% / 92.0%
/// to 95.8% / 94.1% (similarity 0.5).
public struct SpeakerChangeDetector: Sendable {
    /// A window less similar than this to the current piece sounds like someone else.
    public var threshold: Float = 0.5
    public var confirmations = 2
    public var windowMs = 1_500
    public var hopMs = 500
    /// Neither side of a change may be shorter than this.
    public var minPieceMs = 1_500

    private var pieceStart = 0
    private var profile: [Float]?
    private var below = 0
    private var firstBelow: Int?

    public init() {}

    /// A new sentence (or piece) starts at `sample` (absolute).
    public mutating func start(at sample: Int) {
        pieceStart = sample
        profile = nil
        below = 0
        firstBelow = nil
    }

    /// Feeds the embedding of the window starting at `windowStart` (absolute). Returns the
    /// estimated change point when another speaker has taken over.
    public mutating func observe(_ embedding: [Float], windowStart: Int) -> Int? {
        guard let unit = OnlineSpeakerClusterer.normalized(embedding) else { return nil }
        guard let current = profile, let centroid = OnlineSpeakerClusterer.normalized(current) else {
            profile = unit
            return nil
        }
        let similarity = zip(centroid, unit).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        guard similarity < threshold else {
            below = 0
            firstBelow = nil
            profile = zip(current, unit).map { $0 + $1 }
            return nil
        }
        below += 1
        if firstBelow == nil { firstBelow = windowStart }
        guard below >= confirmations, let changed = firstBelow else { return nil }
        below = 0
        firstBelow = nil
        let boundary = changed + AudioSpec.samples(forMilliseconds: windowMs / 2)
        guard boundary - pieceStart >= AudioSpec.samples(forMilliseconds: minPieceMs) else { return nil }
        pieceStart = boundary
        profile = unit
        return boundary
    }
}
