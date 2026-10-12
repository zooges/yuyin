import Foundation
import YuyinCore

/// Protects against recognizers that "hear" words in noise (LLM-based models, Paraformer).
///
/// Measured on real recordings: a mouse click became "我操，这这这这…" (Fun-ASR-Nano) or
/// "g 零 axy x s…" (Paraformer) while SenseVoice returned only "。". So:
/// - if the live pass heard nothing, SenseVoice (cheap, RTF ≈ 0.01) first confirms there is speech;
/// - output that looks like a hallucination falls back to SenseVoice / the live text.
public final class GuardedCorrector: CorrectorASREngine, @unchecked Sendable {
    public var providerID: String { primary.providerID }
    private let primary: any CorrectorASREngine
    private var gate: (any CorrectorASREngine)?

    public init(primary: any CorrectorASREngine, gate: (any CorrectorASREngine)?) {
        self.primary = primary
        self.gate = gate
    }

    public func prepare() async throws {
        try await primary.prepare()
        if let gate {
            do { try await gate.prepare() } catch { self.gate = nil }
        }
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        var gateText: String?
        if !TextFilter.isMeaningful(hint), let gate {
            let heard = (try? await gate.correct(samples, hint: "")) ?? ""
            guard TextFilter.isMeaningful(heard) else { return "" }
            gateText = heard
        }
        let text = try await primary.correct(samples, hint: hint)
        let hintUnits = TextFilter.contentUnits(hint)
        // A result far shorter than what the live pass heard means the model failed on this
        // audio (e.g. English through a Chinese-only model) — don't let it erase content.
        let lostContent = hintUnits >= 8 && TextFilter.contentUnits(text) * 2 < hintUnits
        guard TextFilter.looksHallucinated(text) || lostContent else { return text }
        if gateText == nil, let gate {
            gateText = try? await gate.correct(samples, hint: hint)
        }
        let candidates = [gateText, hint].compactMap { $0 }.filter { !TextFilter.looksHallucinated($0) }
        if lostContent, let fuller = candidates.max(by: { TextFilter.contentUnits($0) < TextFilter.contentUnits($1) }),
           TextFilter.contentUnits(fuller) > TextFilter.contentUnits(text) {
            return fuller
        }
        if TextFilter.looksHallucinated(text) {
            return candidates.first ?? ""
        }
        return text
    }

    public func shutdown() async {
        await primary.shutdown()
        await gate?.shutdown()
    }
}

/// Sends sentences whose live text is English to a multilingual recognizer
/// (Paraformer-large only knows Chinese: "YOUR JOB OH MY GOD" became "哥，来玩，问问你啊啊什么？").
public final class LanguageRoutingCorrector: CorrectorASREngine, @unchecked Sendable {
    public private(set) var providerID: String
    private let chinese: any CorrectorASREngine
    private let english: any CorrectorASREngine

    public init(chinese: any CorrectorASREngine, english: any CorrectorASREngine) {
        self.chinese = chinese
        self.english = english
        providerID = chinese.providerID
    }

    public func prepare() async throws {
        try await chinese.prepare()
        try await english.prepare()
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        let engine = TextFilter.isMeaningful(hint) && Language.guess(hint) == .en ? english : chinese
        providerID = engine.providerID
        return try await engine.correct(samples, hint: hint)
    }

    public func shutdown() async {
        await chinese.shutdown()
        await english.shutdown()
    }
}
