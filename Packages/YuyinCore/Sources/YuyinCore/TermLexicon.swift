import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Puts domain terms back where a recognizer wrote a similar-sounding word: "心证" came out as
/// "新政", "权利瑕疵" as "权力瑕疵", "成都航天" as "成都行间" in the user's case discussions.
///
/// Three layers, after CapsWriter-Offline's hotword system:
/// 1. Rules "错写=正确": exact text replacement, for errors that don't sound alike ("备诉=反诉").
/// 2. Same toned pinyin: any term of 2+ characters ("新政" → "心证").
/// 3. Similar sound, only for the user's own names of 3+ characters: initials, finals and tones
///    are compared, near pairs (zh/z, an/ang, l/n…) costing half; ≥ 75% alike, at least half the
///    characters the same, no character off in all three — and in 3-character names only near
///    misses: "徐律师" must not take over "王律师" or "石律师" (other lawyers in the meeting). Built-in terms start with everyday
///    words ("合同编", "意思表示"), so on the 2-hour meeting similar sound turned "合同中" and
///    "意思就是" into them; names don't. Two-character words stay exact: "指正" is one tone
///    away from "质证".
/// Layers 2 and 3 replace only what lines up with word boundaries ("甚至证据" ≠ "质证").
public struct TermLexicon: Sendable {
    private struct Term: Sendable {
        let text: [Character]
        let syllables: [Syllable]
        /// The user's own name: may also replace something that only sounds similar.
        let similar: Bool
    }

    /// Longest first, so a longer term wins over a shorter one inside it.
    private let terms: [Term]
    private let rules: [(from: String, to: String)]
    /// Terms in their order, for recognizers that take hotwords (rule targets, and names with
    /// Latin letters too). Built-in terms are included only when no names are given.
    public let hotwords: [String]

    /// Fuzzy matches need at least this much likeness.
    static let similarity: Double = 0.75
    static let fuzzyMinLength = 3

    /// `terms`: replaced when they sound the same. `names`: the user's words — also replaced when
    /// they sound similar — or rules written "错写=正确" (also "＝" or "→").
    public init(terms: [String] = [], names: [String] = []) {
        var seen: Set<String> = []
        var built: [Term] = []
        var rules: [(String, String)] = []
        var hotwords: [String] = []
        for (raw, similar) in names.map({ ($0, true) }) + terms.map({ ($0, false) }) {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.ruleSeparators.contains(where: entry.contains) {
                // A malformed rule ("a=a", "=x") is dropped, never taken as a term.
                if let rule = Self.rule(entry) {
                    rules.append(rule)
                    if !hotwords.contains(rule.1) { hotwords.append(rule.1) }
                }
                continue
            }
            let chars = Array(entry)
            guard (2...16).contains(chars.count), seen.insert(entry).inserted else { continue }
            if similar || names.isEmpty { hotwords.append(entry) }
            // Only all-Chinese terms: names with Latin letters or digits have no pinyin to match.
            let syllables = chars.compactMap(Syllable.of)
            guard syllables.count == chars.count else { continue }
            built.append(Term(text: chars, syllables: syllables, similar: similar))
        }
        self.terms = built.sorted { $0.text.count > $1.text.count }
        self.rules = rules.sorted { $0.0.count > $1.0.count }
        self.hotwords = hotwords
    }

    static let ruleSeparators = ["=", "＝", "→"]

    /// "错写=正确" → ("错写", "正确").
    static func rule(_ entry: String) -> (String, String)? {
        for separator in ruleSeparators where entry.contains(separator) {
            let parts = entry.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[0] != parts[1] else { return nil }
            return (parts[0], parts[1])
        }
        return nil
    }

    public var isEmpty: Bool { terms.isEmpty && rules.isEmpty }

    public func correct(_ text: String) -> String {
        var text = text
        for rule in rules where text.contains(rule.from) {
            text = text.replacingOccurrences(of: rule.from, with: rule.to)
        }
        guard !terms.isEmpty, text.unicodeScalars.contains(where: Syllable.isHan) else { return text }
        let chars = Array(text)
        let syllables = chars.map(Syllable.of)
        var words: Set<Int>?
        func onWordBoundaries(_ start: Int, _ length: Int) -> Bool {
            if words == nil { words = Self.wordBoundaries(text) }
            return words.map { $0.contains(start) && $0.contains(start + length) } ?? true
        }
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if syllables[i] != nil, let term = bestTerm(at: i, chars: chars, syllables: syllables, onWordBoundaries) {
                out += term.text
                i += term.text.count
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// Exact text first, then the same sound, then the most similar long term.
    private func bestTerm(at start: Int, chars: [Character], syllables: [Syllable?],
                          _ onWordBoundaries: (Int, Int) -> Bool) -> Term? {
        var fuzzy: (term: Term, score: Double)?
        for term in terms where start + term.text.count <= chars.count {
            let window = chars[start..<(start + term.text.count)]
            if window.elementsEqual(term.text) { return term }
            guard let score = Self.likeness(term.syllables, syllables[start..<(start + term.text.count)]) else { continue }
            if score == 1 {
                if onWordBoundaries(start, term.text.count) { return term }
                continue
            }
            let same = zip(window, term.text).filter { $0 == $1 }.count
            guard term.similar, term.text.count >= Self.fuzzyMinLength, score >= Self.similarity, score > fuzzy?.score ?? 0,
                  2 * same >= term.text.count, Self.everyCharacterNear(term.syllables, syllables[start..<(start + term.text.count)]),
                  onWordBoundaries(start, term.text.count)
            else { continue }
            fuzzy = (term, score)
        }
        return fuzzy?.term
    }

    /// 1 = same toned pinyin; nil when a character has no pinyin.
    static func likeness(_ term: [Syllable], _ text: ArraySlice<Syllable?>) -> Double? {
        var cost = 0.0
        for (expected, heard) in zip(term, text) {
            guard let heard else { return nil }
            cost += Syllable.cost(expected.initial, heard.initial) + Syllable.cost(expected.final, heard.final)
                + (expected.tone == heard.tone ? 0 : 1)
        }
        return 1 - cost / Double(3 * term.count)
    }

    /// The terms `text` probably contains, best first: CapsWriter-Offline's hotword retrieval,
    /// on a first-pass transcript (the live text) instead of its CTC output. A term scores by its
    /// most alike stretch of the text (same measure as the correction); ≥ `threshold` counts.
    public func relevantTerms(in text: String, threshold: Double = 0.6, limit: Int = 20) -> [String] {
        let chars = Array(text)
        let syllables = chars.map(Syllable.of)
        let lowered = text.lowercased()
        var scored: [(term: String, score: Double)] = []
        for term in terms {
            let word = String(term.text)
            if text.contains(word) {
                scored.append((word, 1))
                continue
            }
            var best = 0.0
            if term.text.count <= syllables.count {
                for start in 0...(syllables.count - term.text.count) {
                    if let score = Self.likeness(term.syllables, syllables[start..<(start + term.text.count)]), score > best {
                        best = score
                    }
                }
            }
            if best >= threshold { scored.append((word, best)) }
        }
        // Names with Latin letters or digits: by plain text.
        for word in hotwords where !terms.contains(where: { String($0.text) == word }) && lowered.contains(word.lowercased()) {
            scored.append((word, 1))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.term.count > $1.term.count }
            .prefix(limit).map(\.term)
    }

    /// Each character close enough: in 3-character names one part off (or two near pairs),
    /// in longer ones anything short of all three.
    static func everyCharacterNear(_ term: [Syllable], _ text: ArraySlice<Syllable?>) -> Bool {
        let limit = term.count <= 3 ? 1.0 : 2.0
        return zip(term, text).allSatisfy { expected, heard in
            guard let heard else { return false }
            return Syllable.cost(expected.initial, heard.initial) + Syllable.cost(expected.final, heard.final)
                + (expected.tone == heard.tone ? 0 : 1) <= limit
        }
    }

    /// Character offsets where words start or end, from the system's Chinese word segmenter.
    private static func wordBoundaries(_ text: String) -> Set<Int>? {
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        var bounds: Set<Int> = [0, text.count]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            bounds.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            bounds.insert(text.distance(from: text.startIndex, to: range.upperBound))
            return true
        }
        return bounds
        #else
        return nil
        #endif
    }
}

/// One Chinese character's sound: initial, final and tone ("证" → zh, eng, 4), cached.
struct Syllable: Hashable, Sendable {
    let initial: String
    let final: String
    let tone: Int

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Character: Syllable] = [:]
    private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
                                   "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    /// Pairs recognizers confuse, half the cost of a mismatch (CapsWriter-Offline's list).
    private static let near: Set<String> = {
        let pairs = [("an", "ang"), ("en", "eng"), ("in", "ing"), ("ian", "iang"), ("uan", "uang"),
                     ("z", "zh"), ("c", "ch"), ("s", "sh"), ("l", "n"), ("f", "h"),
                     ("ai", "ei"), ("o", "uo"), ("e", "ie"), ("p", "t"), ("p", "b"), ("t", "d"), ("k", "g")]
        return Set(pairs.flatMap { ["\($0)|\($1)", "\($1)|\($0)"] })
    }()

    static func cost(_ a: String, _ b: String) -> Double {
        a == b ? 0 : near.contains("\(a)|\(b)") ? 0.5 : 1
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    static func of(_ char: Character) -> Syllable? {
        guard char.unicodeScalars.count == 1, let scalar = char.unicodeScalars.first, isHan(scalar) else { return nil }
        if let hit = lock.withLock({ cache[char] }) { return hit }
        #if canImport(Darwin)
        guard let latin = String(char).applyingTransform(.mandarinToLatin, reverse: false),
              let syllable = parse(latin.trimmingCharacters(in: .whitespaces))
        else { return nil }
        lock.withLock { cache[char] = syllable }
        return syllable
        #else
        return nil
        #endif
    }

    /// "zhèng" → (zh, eng, 4); "lǜ" → (l, v, 4); "yǔ" → (y, v, 3); neutral tone is 5.
    static func parse(_ pinyin: String) -> Syllable? {
        var letters = ""
        var tone = 5
        for scalar in pinyin.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x304: tone = 1
            case 0x301: tone = 2
            case 0x30C: tone = 3
            case 0x300: tone = 4
            case 0x308: if letters.hasSuffix("u") { letters.removeLast(); letters += "v" }
            default:
                guard scalar.isASCII, CharacterSet.letters.contains(scalar) else { return nil }
                letters.unicodeScalars.append(scalar)
            }
        }
        guard !letters.isEmpty else { return nil }
        let initial = initials.first { letters.hasPrefix($0) && letters.count > $0.count } ?? ""
        var final = String(letters.dropFirst(initial.count))
        // After j, q, x, y a written "u" is ü.
        if ["j", "q", "x", "y"].contains(initial), final.hasPrefix("u") { final = "v" + final.dropFirst() }
        return Syllable(initial: initial, final: final, tone: tone)
    }
}

/// What a recognizer that reads context (Qwen3-ASR 1.7B) is told before each sentence, after
/// CapsWriter-Offline: the domain, the user's note on the recording, the terms this sentence
/// probably contains (by sound, from its live text) and the text just before it.
public struct RecognitionContext: Sendable {
    public var domain: String?
    /// The user's own words on the recording ("买卖合同纠纷，原告…，被告成都航天").
    public var note: String?
    /// The user's names and rule targets: always given (they are few and case-specific).
    public var names: [String]
    /// Built-in terms, of which the relevant ones are given.
    public var terms: TermLexicon
    /// false: every term, every time (as before retrieval).
    public var selectsTerms: Bool

    public init(domain: String?, note: String?, names: [String], terms: TermLexicon, selectsTerms: Bool = true) {
        self.domain = domain
        self.note = note
        self.names = names
        self.terms = terms
        self.selectsTerms = selectsTerms
    }

    public var isEmpty: Bool { domain == nil && (note ?? "").isEmpty && names.isEmpty && terms.isEmpty }

    /// The system prompt for one sentence; `hint` is its live text, `recent` what came before.
    public func prompt(hint: String, recent: String) -> String? {
        var parts: [String] = []
        if let domain { parts.append(domain) }
        if let note, !note.isEmpty { parts.append("背景：" + note) }
        let picked = selectsTerms ? terms.relevantTerms(in: hint, limit: 15) : terms.hotwords
        let all = names + picked.filter { !names.contains($0) }
        if !all.isEmpty { parts.append("可能出现的术语：" + all.joined(separator: "，")) }
        if !recent.isEmpty { parts.append("上文：" + recent) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// Legal terms general models get wrong, kept to words whose same-sounding twins are not
/// legal words themselves: "权利" / "权力" and "定金" / "订金" are both law, so only the
/// longer, unambiguous compounds are listed.
public enum LegalVocabulary {
    public static let terms: [String] = [
        // Evidence and proof
        "心证", "自由心证", "质证", "质证意见", "举证", "举证责任", "举证期限", "证明力", "证据链", "证据目录",
        "书证", "物证", "电子数据", "证人证言", "鉴定意见", "司法鉴定", "自认",
        // Claims and procedure
        "反诉", "本诉", "诉请", "诉讼请求", "案涉", "涉案", "管辖权异议", "诉讼时效", "除斥期间",
        "诉讼保全", "财产保全", "发回重审", "庭前会议", "合议庭", "审判长", "书记员", "裁定书", "判决书",
        "调解书", "起诉状", "答辩状", "上诉状", "代理词", "被上诉人", "上诉人", "被申请人", "诉讼代理人",
        "法定代表人", "实际控制人", "强制执行", "执行异议", "再审申请",
        // Contracts
        "权利瑕疵", "瑕疵担保", "催告", "解除权", "解除函", "解除通知", "意思表示", "履行", "履约",
        "不安抗辩", "同时履行抗辩", "情势变更", "显失公平", "缔约过失", "格式条款", "效力待定", "表见代理",
        "违约金", "可得利益", "逾期交付", "质保金", "标的物", "对赌",
        // Liability and property
        "不当得利", "无因管理", "连带责任", "保证责任", "追偿权", "代位权", "撤销权", "善意取得", "留置权",
        "法人人格否认", "商业秘密",
        // Criminal
        "取保候审", "认罪认罚", "辩护人", "公诉", "缓刑",
        // Sources of law
        "司法解释", "民法典", "合同编", "通则编", "民事诉讼法", "最高人民法院",
    ]
}
