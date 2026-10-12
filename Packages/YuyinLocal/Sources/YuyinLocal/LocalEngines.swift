import Foundation
import YuyinCore

/// Resolves user choices against installed models. The same resolution drives both
/// engine construction and the UI summary, so what the UI shows is what runs.
public struct LocalEngines: Sendable {
    public enum Streaming: Equatable, Sendable {
        case sherpa
        case appleSpeech
    }

    public enum Corrector: Equatable, Sendable {
        case senseVoiceANE
        case sherpa(SherpaOfflineCorrector.Kind)
        case appleSpeech
        case none
    }

    public let locator: ModelLocator
    /// Injected for tests; defaults to the real device capability.
    private let onDeviceSpeech: @Sendable () -> Bool
    /// User vocabulary for models that support it (comma-separated).
    public var hotwords: String = ""

    public init(locator: ModelLocator = .standard, onDeviceSpeech: (@Sendable () -> Bool)? = nil) {
        self.locator = locator
        self.onDeviceSpeech = onDeviceSpeech ?? { AppleSpeech.isOnDeviceSupported }
    }

    // MARK: - Resolution

    public func resolveStreaming(_ choice: StreamingEngineChoice) throws -> Streaming {
        let sherpaReady = locator.isInstalled(.streamingZipformer)
        switch choice {
        case .sherpa:
            guard sherpaReady else { throw ASRError.modelMissing(ModelKind.streamingZipformer.title) }
            return .sherpa
        case .appleSpeech:
            return .appleSpeech
        case .auto:
            if sherpaReady { return .sherpa }
            guard onDeviceSpeech() else { throw ASRError.modelMissing(ModelKind.streamingZipformer.title) }
            return .appleSpeech
        }
    }

    public func resolveCorrector(_ choice: CorrectorChoice) throws -> Corrector {
        func require(_ kind: ModelKind, _ plan: Corrector) throws -> Corrector {
            guard locator.isInstalled(kind) else { throw ASRError.modelMissing(kind.title) }
            return plan
        }
        switch choice {
        case .paraformer: return try require(.paraformer, .sherpa(.paraformer))
        case .senseVoiceANE: return try require(.senseVoiceANE, .senseVoiceANE)
        case .senseVoice: return try require(.senseVoice, .sherpa(.senseVoice))
        case .fireRed: return try require(.fireRed, .sherpa(.fireRed))
        case .funASRNano: return try require(.funASRNano, .sherpa(.funASRNano))
        case .qwen3ASR: return try require(.qwen3ASR, .sherpa(.qwen3))
        case .appleSpeech: return .appleSpeech
        case .none: return .none
        case .auto:
            // Ordered by accuracy measured on real recordings (see docs/plans, 识别评测).
            for (kind, plan) in Self.autoOrder where locator.isInstalled(kind) {
                return plan
            }
            return .none
        }
    }

    static var autoOrder: [(ModelKind, Corrector)] {
        #if os(macOS)
        // Fun-ASR-Nano: best on mixed Chinese/English and English; Paraformer: fast, Chinese only.
        return [
            (.funASRNano, .sherpa(.funASRNano)),
            (.paraformer, .sherpa(.paraformer)),
            (.senseVoiceANE, .senseVoiceANE),
            (.senseVoice, .sherpa(.senseVoice)),
            (.fireRed, .sherpa(.fireRed)),
        ]
        #else
        // ~1 GB LLM models are heavy on a phone.
        return [
            (.paraformer, .sherpa(.paraformer)),
            (.senseVoiceANE, .senseVoiceANE),
            (.senseVoice, .sherpa(.senseVoice)),
            (.funASRNano, .sherpa(.funASRNano)),
        ]
        #endif
    }

    // MARK: - Construction

    public func makeStreaming(_ plan: Streaming) throws -> any StreamingASREngine {
        switch plan {
        case .sherpa: return SherpaStreamingEngine(files: try locator.streamingFiles())
        case .appleSpeech: return AppleSpeechStreamingEngine()
        }
    }

    public func makeCorrector(_ plan: Corrector) throws -> (any CorrectorASREngine)? {
        switch plan {
        case .senseVoiceANE:
            return FluidSenseVoiceCorrector(directory: locator.directory(for: .senseVoiceANE))
        case .sherpa(let kind):
            let punctuation = kind.needsPunctuation ? try? locator.singleModel(.punctuation) : nil
            // Without a language, Fun-ASR-Nano turned short Chinese exclamations into Japanese
            // ("这波" → "ちょっと。"); with "中文" English sentences still come out in English.
            let engine = SherpaOfflineCorrector(
                kind: kind, files: try locator.offlineFiles(kind.modelKind),
                hotwords: hotwords, punctuationModel: punctuation,
                promptLanguage: kind == .funASRNano ? "中文" : ""
            )
            // SenseVoice answers "。" to noise; the others may invent words, so guard them.
            let guarded = kind == .senseVoice ? GuardedCorrector(primary: engine, gate: nil)
                : GuardedCorrector(primary: engine, gate: makeGate())
            if kind == .paraformer, let english = makeEnglishCorrector() {
                return LanguageRoutingCorrector(chinese: guarded, english: english)
            }
            return guarded
        case .appleSpeech:
            return AppleSpeechCorrector()
        case .none:
            return nil
        }
    }

    /// SenseVoice in English mode, for English sentences when the main model is Chinese-only.
    private func makeEnglishCorrector() -> (any CorrectorASREngine)? {
        guard let files = try? locator.offlineFiles(.senseVoice) else { return nil }
        return SherpaOfflineCorrector(kind: .senseVoice, files: files, language: "en")
    }

    /// Cheap "is there speech at all?" check (SenseVoice), if installed.
    private func makeGate() -> (any CorrectorASREngine)? {
        if locator.isInstalled(.senseVoiceANE) {
            return FluidSenseVoiceCorrector(directory: locator.directory(for: .senseVoiceANE))
        }
        if let files = try? locator.offlineFiles(.senseVoice) {
            return SherpaOfflineCorrector(kind: .senseVoice, files: files)
        }
        return nil
    }

    public func makeSpeakerLabeler() -> (any SpeakerLabeling)? {
        guard let model = try? locator.singleModel(.speakerEmbedding) else { return nil }
        return SherpaSpeakerLabeler(model: model)
    }

    public var canLabelSpeakers: Bool {
        locator.isInstalled(.speakerEmbedding)
    }
}

public extension LocalEngines.Streaming {
    var title: String {
        switch self {
        case .sherpa: return "Sherpa Zipformer"
        case .appleSpeech: return "系统语音识别"
        }
    }
}

extension SherpaOfflineCorrector.Kind {
    var needsPunctuation: Bool { self == .paraformer || self == .fireRed }

    var modelKind: ModelKind {
        switch self {
        case .senseVoice: return .senseVoice
        case .paraformer: return .paraformer
        case .fireRed: return .fireRed
        case .qwen3: return .qwen3ASR
        case .funASRNano: return .funASRNano
        }
    }
}

public extension LocalEngines.Corrector {
    var title: String {
        switch self {
        case .senseVoiceANE: return "SenseVoice（神经网络引擎）"
        case .sherpa(.senseVoice): return "SenseVoice"
        case .sherpa(.paraformer): return "Paraformer"
        case .sherpa(.fireRed): return "FireRedASR"
        case .sherpa(.qwen3): return "Qwen3-ASR"
        case .sherpa(.funASRNano): return "Fun-ASR-Nano"
        case .appleSpeech: return "系统语音识别"
        case .none: return "不纠错"
        }
    }
}
