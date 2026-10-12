import Foundation

/// A language model that completes one chat turn (润色 runs on it).
public protocol TextGenerating: AnyObject, Sendable {
    func prepare() async throws
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
    func shutdown() async
}

/// 润色, after CapsWriter-Offline's LLM roles: a transcript rewritten as a clean written record
/// by a local model. Fillers and stutters go, obvious same-sounding errors and legal terms are
/// fixed, nothing is added or summarized.
///
/// It works on turns (one speaker's consecutive sentences, up to `paragraphCharacters`), not
/// sentences: asked to keep sentence-for-sentence alignment, the model re-cut the transcript's
/// fragments and the lines no longer matched. A turn's text goes to its first sentence; the
/// rest of the turn is marked merged ("").
public enum TranscriptPolish {
    public struct Paragraph: Equatable, Sendable {
        public let ids: [UUID]
        public let speaker: String?
        public let text: String
    }

    /// Longer turns gave a 4B model room to summarize ("提前准备了上述证据链", never said).
    public static let paragraphCharacters = 250
    /// Characters of transcript per request: enough context, short enough to answer fast.
    public static let batchCharacters = 1_200

    /// One speaker's consecutive sentences; sentences with nothing said are left out.
    public static func paragraphs(_ utterances: [Utterance], book: SpeakerBook) -> [Paragraph] {
        var result: [Paragraph] = []
        var ids: [UUID] = []
        var speakerIndex: Int??
        var text = ""
        func flush() {
            if !ids.isEmpty {
                result.append(Paragraph(ids: ids, speaker: speakerIndex.flatMap { book.label(for: $0) }, text: text))
            }
            ids = []
            text = ""
        }
        for u in utterances where TextFilter.isMeaningful(u.displayText) {
            if speakerIndex != .some(u.speakerIndex) || text.count + u.displayText.count > paragraphCharacters {
                flush()
                speakerIndex = .some(u.speakerIndex)
            }
            ids.append(u.id)
            text += u.displayText
        }
        flush()
        return result
    }

    public static func batches(_ paragraphs: [Paragraph]) -> [[Paragraph]] {
        var batches: [[Paragraph]] = []
        var current: [Paragraph] = []
        var size = 0
        for paragraph in paragraphs {
            if size + paragraph.text.count > batchCharacters, !current.isEmpty {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(paragraph)
            size += paragraph.text.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    public static func system(background: String?, terms: [String]) -> String {
        var prompt = """
        你是法律会议记录的校对员。这是会议录音的逐字转写，请做最小改动的整理，忠实保留说话人的原话：
        1. 只删除口头禅、语气词和口吃重复（如“呃”“嗯”“那个”“这个这个”“我我我”）；
        2. 修正明显的同音错字，法律术语、人名、公司名按背景和术语写对；
        3. 转写常把一句话切断，把它连起来，补全或修正标点；
        4. 原话的每一层意思都要保留，顺序不变；不得改写成书面总结，不得增加原话没有的内容，不得省略。
        示例：“呃，这个这个合同我我们是，是逾期交付的，所以呢就是说我们要解。除” → “这个合同我们是逾期交付的，所以我们要解除。”
        输入是若干段发言，每段以“【编号】说话人：”开头。按顺序对每段输出“【编号】整理后的文字”，编号与输入一一对应，不合并段落，不输出其他内容。
        """
        if let background, !background.isEmpty { prompt += "\n背景：" + background }
        if !terms.isEmpty { prompt += "\n术语：" + terms.joined(separator: "，") }
        return prompt
    }

    public static func user(_ paragraphs: [Paragraph]) -> String {
        var text = ""
        for (index, paragraph) in paragraphs.enumerated() {
            text += "【\(index + 1)】\(paragraph.speaker ?? "发言")：\(paragraph.text)\n\n"
        }
        return text
    }

    /// One text per paragraph, or nil when the answer doesn't line up (a paragraph missing,
    /// twice or out of order): then the batch keeps its original text.
    public static func parse(_ output: String, count: Int) -> [String]? {
        var texts: [String] = []
        var rest = Substring(output)
        while let open = rest.firstIndex(of: "【") {
            guard let close = rest[open...].firstIndex(of: "】"),
                  let number = Int(rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)),
                  number == texts.count + 1
            else { return nil }
            let body = rest[rest.index(after: close)...]
            let end = body.firstIndex(of: "【") ?? body.endIndex
            var text = body[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            // Some answers repeat the speaker: "【1】徐律师：……".
            if let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }), text.distance(from: text.startIndex, to: colon) <= 12,
               !text[..<colon].contains(where: { "，。？！,.?!".contains($0) }) {
                text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            texts.append(text)
            rest = body[end...]
        }
        return texts.count == count ? texts : nil
    }

    /// Whether `polished` still says what `original` said: most of the original's content
    /// (character pairs, fillers aside) is kept, and little is new. A rewrite that summarizes or
    /// invents fails, and that turn keeps its original text.
    public static func isFaithful(_ polished: String, to original: String) -> Bool {
        func pairs(_ text: String) -> [String] {
            let chars = Array(text.filter { ($0.isLetter || $0.isNumber) && !"呃嗯啊哦哎呀吧嘛呢".contains($0) })
            return chars.count < 2 ? [] : (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
        }
        let before = pairs(original), after = pairs(polished)
        guard !before.isEmpty, !after.isEmpty else { return after.isEmpty == before.isEmpty }
        let beforeSet = Set(before), afterSet = Set(after)
        let kept = Double(beforeSet.intersection(afterSet).count) / Double(beforeSet.count)
        let new = Double(after.filter { !beforeSet.contains($0) }.count) / Double(after.count)
        return kept >= 0.6 && new <= 0.3
    }

    /// Polishes `utterances`; returns per sentence the turn's new text (first sentence of a
    /// turn) or "" (merged into it). `progress` gets 0…1.
    public static func run(
        _ utterances: [Utterance], book: SpeakerBook, model: any TextGenerating,
        background: String?, terms: [String], progress: @Sendable (Double) -> Void
    ) async throws -> [UUID: String] {
        let batches = batches(paragraphs(utterances, book: book))
        let system = system(background: background, terms: terms)
        var result: [UUID: String] = [:]
        for (index, paragraphs) in batches.enumerated() {
            try Task.checkCancellation()
            let budget = paragraphs.reduce(0) { $0 + $1.text.count } * 2 + 64
            var texts: [String]?
            // One retry: a rare answer drops or merges a paragraph.
            for _ in 0..<2 where texts == nil {
                let answer = try await model.complete(system: system, user: user(paragraphs), maxTokens: budget)
                texts = parse(answer, count: paragraphs.count)
            }
            for (offset, paragraph) in paragraphs.enumerated() {
                let rewrite = texts?[offset]
                // A rewrite that drifted from what was said: only the safe cleanup, by rule.
                let text = rewrite.flatMap { TextFilter.isMeaningful($0) && isFaithful($0, to: paragraph.text) ? $0 : nil }
                    ?? TextFilter.removingFillers(paragraph.text)
                guard TextFilter.isMeaningful(text) else { continue }
                result[paragraph.ids[0]] = text
                for id in paragraph.ids.dropFirst() { result[id] = "" }
            }
            progress(Double(index + 1) / Double(batches.count))
        }
        return result
    }
}
