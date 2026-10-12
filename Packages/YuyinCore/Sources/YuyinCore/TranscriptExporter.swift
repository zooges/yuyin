import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case srt
    case markdown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plainText: return "纯文本"
        case .srt: return "SRT 字幕"
        case .markdown: return "Markdown"
        }
    }

    public var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .srt: return "srt"
        case .markdown: return "md"
        }
    }
}

public enum TranscriptExporter {
    /// - Parameters:
    ///   - speakerNames: user-given names; unnamed speakers get "说话人 N".
    ///   - includeTranslation: add each sentence's translation on its own line.
    public static func export(
        _ utterances: [Utterance],
        format: ExportFormat,
        title: String? = nil,
        speakerNames: [Int: String] = [:],
        includeTranslation: Bool = true
    ) -> String {
        let book = SpeakerBook(names: speakerNames)
        let lines = utterances
            .filter { TextFilter.isMeaningful($0.displayText) }
            .sorted { $0.startMs < $1.startMs }
        func translation(_ u: Utterance) -> String? {
            guard includeTranslation, let t = u.translation, !t.isEmpty else { return nil }
            return t
        }
        switch format {
        case .plainText:
            return lines.map { u in
                var line = book.label(for: u.speakerIndex).map { "[\($0)] \(u.displayText)" } ?? u.displayText
                if let t = translation(u) { line += "\n    \(t)" }
                return line
            }.joined(separator: "\n")

        case .markdown:
            var out = ["# \(title ?? "转写稿")", ""]
            for u in lines {
                let clock = clockLabel(u.startMs)
                if let speaker = book.label(for: u.speakerIndex) {
                    out.append("- **\(clock)** · *\(speaker)* — \(u.displayText)")
                } else {
                    out.append("- **\(clock)** \(u.displayText)")
                }
                if let t = translation(u) { out.append("  > \(t)") }
            }
            return out.joined(separator: "\n")

        case .srt:
            return lines.enumerated().map { i, u in
                let end = max(u.endMs ?? (u.startMs + 2000), u.startMs + 500)
                var body = book.label(for: u.speakerIndex).map { "[\($0)] \(u.displayText)" } ?? u.displayText
                if let t = translation(u) { body += "\n\(t)" }
                return "\(i + 1)\n\(srtTime(u.startMs)) --> \(srtTime(end))\n\(body)"
            }.joined(separator: "\n\n") + (lines.isEmpty ? "" : "\n")
        }
    }

    /// `mm:ss`, or `h:mm:ss` from one hour on.
    public static func clockLabel(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func srtTime(_ ms: Int) -> String {
        let ms = max(0, ms)
        return String(
            format: "%02d:%02d:%02d,%03d",
            ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000
        )
    }
}
