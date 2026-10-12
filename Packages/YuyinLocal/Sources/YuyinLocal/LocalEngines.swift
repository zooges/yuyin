import Foundation
import YuyinCore

/// Resolves user choices against installed models. The same resolution drives both
/// engine construction and the UI summary, so what the UI shows is what runs.
public struct LocalEngines: Sendable {
    public enum Streaming: Equatable, Sendable {
        case xasr
        /// Zipformer (2023), before X-ASR.
        case sherpa
        case appleSpeech
    }

    public enum Corrector: Equatable, Sendable {
        /// Qwen3-ASR 1.7B through llama.cpp (macOS).
        case llamaQwen3
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
    /// Context for models that read it (Qwen3-ASR 1.7B): the domain and its terms.
    public var background: String?

    public init(locator: ModelLocator = .standard, onDeviceSpeech: (@Sendable () -> Bool)? = nil) {
        self.locator = locator
        self.onDeviceSpeech = onDeviceSpeech ?? { AppleSpeech.isOnDeviceSupported }
    }

    // MARK: - Resolution

    public func resolveStreaming(_ choice: StreamingEngineChoice) throws -> Streaming {
        // X-ASR when installed: on the user's legal meeting its live text had ~40% fewer errors.
        let sherpa: Streaming? = locator.isInstalled(.streamingXASR) ? .xasr
            : locator.isInstalled(.streamingZipformer) ? .sherpa : nil
        switch choice {
        case .sherpa:
            guard let sherpa else { throw ASRError.modelMissing(ModelKind.streamingXASR.title) }
            return sherpa
        case .appleSpeech:
            return .appleSpeech
        case .auto:
            if let sherpa { return sherpa }
            guard onDeviceSpeech() else { throw ASRError.modelMissing(ModelKind.streamingXASR.title) }
            return .appleSpeech
        }
    }

    public func resolveCorrector(_ choice: CorrectorChoice) throws -> Corrector {
        func require(_ kind: ModelKind, _ plan: Corrector) throws -> Corrector {
            guard locator.isInstalled(kind) else { throw ASRError.modelMissing(kind.title) }
            return plan
        }
        switch choice {
        case .qwen3ASRLarge:
            guard Self.supportsLlama else { throw ASRError.unavailable("Qwen3-ASR 1.7B 仅支持 Mac") }
            return try require(.qwen3ASRLarge, .llamaQwen3)
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
        // Qwen3-ASR 1.7B: most accurate on the user's legal meeting and, on the GPU, fastest.
        // Fun-ASR-Nano: best on mixed Chinese/English and English; Paraformer: fast, Chinese only.
        return [
            (.qwen3ASRLarge, .llamaQwen3),
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
        case .xasr:
            return SherpaStreamingEngine(files: try locator.streamingFiles(in: locator.directory(for: .streamingXASR)),
                                         providerID: "sherpa-x-asr")
        case .sherpa: return SherpaStreamingEngine(files: try locator.streamingFiles())
        case .appleSpeech: return AppleSpeechStreamingEngine()
        }
    }

    /// llama.cpp is linked on macOS only (its xcframework has no iOS simulator slice).
    public static var supportsLlama: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    public func makeCorrector(_ plan: Corrector) throws -> (any CorrectorASREngine)? {
        switch plan {
        case .llamaQwen3:
            #if canImport(llama)
            let files = try locator.ggufFiles()
            // LLM-based: guard against words invented from noise, like the others.
            return GuardedCorrector(
                primary: LlamaASRCorrector(model: files.model, projector: files.projector, background: background),
                gate: makeGate()
            )
            #else
            throw ASRError.unavailable("Qwen3-ASR 1.7B 仅支持 Mac")
            #endif
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

    /// The bundled Silero VAD; used in every mode, since segmentation always runs on device.
    public func makeVoiceDetector() -> (any VoiceActivityDetecting)? {
        SherpaVoiceDetector.bundledModel.map { SherpaVoiceDetector(model: $0) }
    }

    public var canLabelSpeakers: Bool {
        locator.isInstalled(.speakerEmbedding)
    }
}

public extension LocalEngines.Streaming {
    var title: String {
        switch self {
        case .xasr: return "X-ASR"
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
        case .llamaQwen3: return "Qwen3-ASR 1.7B"
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
