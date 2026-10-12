import Foundation

public enum TranscriptMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case offline
    case hybrid
    case cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .offline: return "纯离线"
        case .hybrid: return "混合"
        case .cloud: return "纯云端"
        }
    }

    public var detail: String {
        switch self {
        case .offline: return "实时与纠错都在本机，音频不出设备"
        case .hybrid: return "本机实时字幕，句末上传云端纠错；失败时回退本机"
        case .cloud: return "实时与纠错都走云端"
        }
    }

    public var requiresCloud: Bool { self != .offline }
}

public enum UtteranceStatus: String, Codable, Sendable {
    /// Streaming text, sentence still open.
    case partial
    /// Sentence closed, second pass running.
    case pendingCorrection
    case final
    /// Second pass failed; `partial` is kept.
    case failed
}

public struct Utterance: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// Offsets from session start, in audio time (paused time excluded).
    public var startMs: Int
    public var endMs: Int?
    public var partial: String
    public var finalText: String?
    public var status: UtteranceStatus
    /// Engine that produced the visible text.
    public var provider: String
    public var errorMessage: String?
    /// 0-based speaker cluster; nil = unknown.
    public var speakerIndex: Int?
    /// Translation of the final text (when live translation is on).
    public var translation: String?

    public init(
        id: UUID = UUID(),
        startMs: Int,
        endMs: Int? = nil,
        partial: String = "",
        finalText: String? = nil,
        status: UtteranceStatus = .partial,
        provider: String,
        errorMessage: String? = nil,
        speakerIndex: Int? = nil,
        translation: String? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.partial = partial
        self.finalText = finalText
        self.status = status
        self.provider = provider
        self.errorMessage = errorMessage
        self.speakerIndex = speakerIndex
        self.translation = translation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startMs = try c.decodeIfPresent(Int.self, forKey: .startMs) ?? 0
        endMs = try c.decodeIfPresent(Int.self, forKey: .endMs)
        partial = try c.decodeIfPresent(String.self, forKey: .partial) ?? ""
        finalText = try c.decodeIfPresent(String.self, forKey: .finalText)
        status = try c.decodeIfPresent(UtteranceStatus.self, forKey: .status) ?? .final
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        speakerIndex = try c.decodeIfPresent(Int.self, forKey: .speakerIndex)
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
    }

    public var displayText: String {
        if status == .final, let finalText { return finalText }
        return partial
    }

    /// Default label; user-given names live in `SpeakerBook` / `Meeting.speakerNames`.
    public var speakerName: String? {
        speakerIndex.map(SpeakerBook.defaultLabel)
    }
}

public enum SessionPhase: String, Sendable {
    case idle
    case preparing
    case listening
    case paused
    /// Input closed; waiting for queued corrections.
    case finishing
}

/// What actually runs, as resolved at session start.
public struct EngineInfo: Equatable, Sendable {
    public var streaming: String
    public var corrector: String?
    public var fallbackCorrector: String?
    public var speakerLabeling: Bool
    public var translator: String?

    public init(
        streaming: String,
        corrector: String?,
        fallbackCorrector: String? = nil,
        speakerLabeling: Bool = false,
        translator: String? = nil
    ) {
        self.streaming = streaming
        self.corrector = corrector
        self.fallbackCorrector = fallbackCorrector
        self.speakerLabeling = speakerLabeling
        self.translator = translator
    }
}

public enum TranscriptEvent: Sendable {
    case phase(SessionPhase)
    case engines(EngineInfo)
    case upsert(Utterance)
    case remove(UUID)
    case notice(String)
}

public enum TextFilter {
    /// False for empty / punctuation-only results (e.g. a corrector returning "。" on noise).
    public static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// "YOUR JOB OH MY GOD" → "Your job oh my god". Streaming English (and occasionally an LLM
    /// recognizer) comes out in capitals; Chinese characters and mixed-case text are untouched.
    public static func normalizeCase(_ text: String) -> String {
        let letters = text.filter { $0.isASCII && $0.isLetter }
        guard letters.count >= 6, !letters.contains(where: { $0.isLowercase }) else { return text }
        var out = ""
        var capitalizeNext = true
        let chars = Array(text.lowercased())
        for (i, ch) in chars.enumerated() {
            var c = ch
            if ch.isASCII && ch.isLetter {
                let standaloneI = ch == "i" && (i == 0 || !chars[i - 1].isLetter) && (i + 1 == chars.count || !chars[i + 1].isLetter)
                if capitalizeNext || standaloneI { c = Character(ch.uppercased()) }
                capitalizeNext = false
            } else if ".?!。？！".contains(ch) {
                capitalizeNext = true
            }
            out.append(c)
        }
        return out
    }

    /// English sentences from a Chinese-prompted recognizer come with full-width punctuation
    /// ("Entrepreneur，and I also do…"): use ASCII punctuation when the text is mostly Latin.
    public static func normalizePunctuation(_ text: String) -> String {
        guard Language.guess(text) == .en, text.contains(where: { "，。？！：；".contains($0) }) else { return text }
        let map: [Character: String] = ["，": ", ", "。": ". ", "？": "? ", "！": "! ", "：": ": ", "；": "; "]
        var out = ""
        for ch in text { out += map[ch] ?? String(ch) }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.replacingOccurrences(of: " ,", with: ",").trimmingCharacters(in: .whitespaces)
    }

    /// An LLM recognizer stuck in a loop: a stretch of 12+ characters said twice in a row, of
    /// 5+ characters three times, or of 16+ characters twice anywhere (punctuation aside).
    /// Qwen3-ASR wrote "除非是你当时你的。" dozens of times, or a whole sentence twice, on the
    /// user's meeting. Real speech repeats shorter bits ("我我我", "这个这个", "对对对").
    public static func repetitionLoop(_ text: String) -> Range<Int>? {
        let chars = Array(text.filter { $0.isLetter || $0.isNumber })
        if let run = consecutiveRepeat(chars) { return run.start..<(run.start + run.period * run.copies) }
        if let copy = repeatedStretch(chars) { return copy.second..<(copy.second + copy.length) }
        return nil
    }

    /// Keeps one copy of each looped stretch (the last resort when retries loop too).
    public static func collapsingRepetition(_ text: String) -> String {
        var text = text
        for _ in 0..<10 {
            let content = text.indices.filter { text[$0].isLetter || text[$0].isNumber }
            let chars = content.map { text[$0] }
            func index(_ offset: Int) -> String.Index { offset < content.count ? content[offset] : text.endIndex }
            if let run = consecutiveRepeat(chars) {
                text.removeSubrange(index(run.start + run.period)..<index(run.start + run.period * run.copies))
            } else if let copy = repeatedStretch(chars) {
                text.removeSubrange(index(copy.second)..<index(copy.second + copy.length))
            } else {
                break
            }
        }
        return text
    }

    private static func consecutiveRepeat(_ chars: [Character]) -> (start: Int, period: Int, copies: Int)? {
        let n = chars.count
        guard n >= 10 else { return nil }
        for period in 5...max(5, min(60, n / 2)) {
            let needed = period >= 12 ? 2 : 3
            guard period * needed <= n else { continue }
            for start in 0...(n - period * needed) {
                var copies = 1
                while start + period * (copies + 1) <= n,
                      chars[(start + period * copies)..<(start + period * (copies + 1))] == chars[start..<(start + period)] {
                    copies += 1
                }
                if copies >= needed { return (start, period, copies) }
            }
        }
        return nil
    }

    /// A 16+ character stretch that appears again later, with the longest match at the copy.
    private static func repeatedStretch(_ chars: [Character], length: Int = 16) -> (second: Int, length: Int)? {
        guard chars.count >= 2 * length else { return nil }
        var seen: [String: Int] = [:]
        for start in 0...(chars.count - length) {
            let key = String(chars[start..<(start + length)])
            if let first = seen[key], start >= first + length {
                var matched = length
                while start + matched < chars.count, chars[first + matched] == chars[start + matched], first + matched < start {
                    matched += 1
                }
                return (start, matched)
            }
            if seen[key] == nil { seen[key] = start }
        }
        return nil
    }

    /// An early correction of a sentence still being spoken, then the live text heard after it.
    /// The correction ends a little later than the live text it replaced, so the live text
    /// starts by repeating its last words ("…在自己。" + "在自己生产…"), and the corrector closed
    /// it with a full stop although the sentence goes on.
    public static func joinCorrected(_ corrected: String, live tail: String) -> String {
        var head = corrected
        while let last = head.last, "。.？?！!".contains(last) { head.removeLast() }
        let headContent = head.filter { $0.isLetter || $0.isNumber }
        let tailChars = Array(tail)
        var best = 0
        var dropUntil = 0
        // The longest start of the tail (punctuation aside) that the head already ends with.
        var content: [Character] = []
        for (index, char) in tailChars.enumerated() {
            guard char.isLetter || char.isNumber else { continue }
            content.append(char)
            if content.count > 8 { break }
            if headContent.hasSuffix(String(content)) {
                best = content.count
                dropUntil = index + 1
            }
        }
        let rest = best > 0 ? String(tailChars[dropUntil...]) : tail
        // The early correction may end anywhere in a clause: no punctuation of our own.
        return head + rest.drop { $0 == " " }
    }

    /// Drops spaces next to Chinese characters and punctuation ("首期款， 通过" from X-ASR's
    /// BPE output); spaces between Latin words stay.
    public static func tightenChineseSpacing(_ text: String) -> String {
        guard text.contains(" ") else { return text }
        return text.replacingOccurrences(
            of: #"\s+(?=[\p{Han}，。？！、；：])|(?<=[\p{Han}，。？！、；：])\s+"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    /// Japanese kana or Korean hangul. Yuyin transcribes Chinese and English; multilingual
    /// recognizers sometimes turn short exclamations into Japanese ("这波" → "ちょっと。").
    public static func containsForeignScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true // kana (not "・")
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return true // hangul
            default: return false
            }
        }
    }

    /// Rough amount of content: Chinese characters plus Latin words.
    public static func contentUnits(_ text: String) -> Int {
        let han = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let words = text.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).count
        return han + words
    }

    /// Typical output of a recognizer fed noise instead of speech: the same character 4+ times
    /// in a row ("这这这这"), a run of stray Latin letters in Chinese text ("g 零 axy x s"),
    /// or Japanese / Korean script.
    /// `maxRun`: this many times the same character in a row counts as invented. Fun-ASR-Nano
    /// turned a mouse click into "这这这这…"; Qwen3-ASR writes real stutters ("你你你你") as said.
    public static func looksHallucinated(_ text: String, maxRun: Int = 4) -> Bool {
        if containsForeignScript(text) { return true }
        var run = 1
        var previous: Character?
        for ch in text where !ch.isWhitespace && !ch.isPunctuation {
            if ch == previous {
                run += 1
                if run >= maxRun { return true }
            } else {
                run = 1
                previous = ch
            }
        }
        let strayLatin = text.split(whereSeparator: { $0.isWhitespace }).filter { token in
            token.count <= 3 && token.allSatisfy { $0.isASCII && $0.isLetter }
        }
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return strayLatin.count >= 3 && han > 0
    }
}
