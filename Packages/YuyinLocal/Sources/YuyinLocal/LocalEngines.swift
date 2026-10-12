import Foundation
import YuyinCore

/// Resolves user choices against installed models. The same resolution drives both
/// engine construction and the UI summary, so what the UI shows is what runs.
public struct LocalEngines: Sendable {
    public enum Streaming: Equatable, Sendable {
        case xasrFast
        case xasr
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
    /// Context for models that read it (Qwen3-ASR 1.7B).
    public var context: RecognitionContext?

    public init(locator: ModelLocator = .standard, onDeviceSpeech: (@Sendable () -> Bool)? = nil) {
        self.locator = locator
        self.onDeviceSpeech = onDeviceSpeech ?? { AppleSpeech.isOnDeviceSupported }
    }

    // MARK: - Resolution

    public func resolveStreaming(_ choice: StreamingEngineChoice) throws -> Streaming {
        // On the user's legal meeting X-ASR's live text had ~40% fewer errors than the Zipformer
        // used before. The 160 ms model shows text sooner (0.30 s vs 0.48 s after speech); the
        // user found live text slow, and corrections replace it within seconds anyway.
        let accurate: Streaming? = locator.isInstalled(.streamingXASR) ? .xasr
            : locator.isInstalled(.streamingXASRFast) ? .xasrFast : nil
        let fast: Streaming? = locator.isInstalled(.streamingXASRFast) ? .xasrFast : accurate
        switch choice {
        case .fast:
            guard let fast else { throw ASRError.modelMissing(ModelKind.streamingXASRFast.title) }
            return fast
        case .sherpa:
            guard let accurate else { throw ASRError.modelMissing(ModelKind.streamingXASR.title) }
            return accurate
        case .appleSpeech:
            return .appleSpeech
        case .auto:
            if let fast { return fast }
            guard onDeviceSpeech() else { throw ASRError.modelMissing(ModelKind.streamingXASRFast.title) }
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
        // Qwen3-ASR 1.7B: most accurate on the user's legal meeting (ahead of Fun-ASR-Nano, since
        // removed) and, on the GPU, fastest. Paraformer: fast, Chinese only.
        return [
            (.qwen3ASRLarge, .llamaQwen3),
            (.paraformer, .sherpa(.paraformer)),
            (.senseVoiceANE, .senseVoiceANE),
            (.senseVoice, .sherpa(.senseVoice)),
        ]
        #else
        return [
            (.paraformer, .sherpa(.paraformer)),
            (.senseVoiceANE, .senseVoiceANE),
            (.senseVoice, .sherpa(.senseVoice)),
        ]
        #endif
    }

    // MARK: - Construction

    public func makeStreaming(_ plan: Streaming) throws -> any StreamingASREngine {
        switch plan {
        case .xasrFast:
            return SherpaStreamingEngine(files: try locator.streamingFiles(in: locator.directory(for: .streamingXASRFast)),
                                         providerID: "sherpa-x-asr-160ms")
        case .xasr:
            return SherpaStreamingEngine(files: try locator.streamingFiles(in: locator.directory(for: .streamingXASR)),
                                         providerID: "sherpa-x-asr")
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
            // LLM-based: guard against words invented from noise, like the others; it writes
            // real stutters ("你你你你") as said, so only longer runs count as invented.
            return GuardedCorrector(
                primary: LlamaASRCorrector(model: files.model, projector: files.projector, context: context),
                gate: makeGate(),
                maxRun: 6
            )
            #else
            throw ASRError.unavailable("Qwen3-ASR 1.7B 仅支持 Mac")
            #endif
        case .senseVoiceANE:
            return FluidSenseVoiceCorrector(directory: locator.directory(for: .senseVoiceANE))
        case .sherpa(let kind):
            let punctuation = kind.needsPunctuation ? try? locator.singleModel(.punctuation) : nil
            let engine = SherpaOfflineCorrector(kind: kind, files: try locator.offlineFiles(kind.modelKind),
                                                punctuationModel: punctuation)
            // SenseVoice answers "。" to noise; Paraformer may invent words, so guard it.
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

    /// The local model for 润色, when downloaded (macOS).
    public func makePolisher() throws -> any TextGenerating {
        #if canImport(llama)
        return LlamaChatModel(model: try locator.polishModelFile())
        #else
        throw ASRError.unavailable("润色仅支持 Mac")
        #endif
    }

    public var canLabelSpeakers: Bool {
        locator.isInstalled(.speakerEmbedding)
    }
}

public extension LocalEngines.Streaming {
    var title: String {
        switch self {
        case .xasrFast: return "X-ASR 低延迟"
        case .xasr: return "X-ASR"
        case .appleSpeech: return "系统语音识别"
        }
    }
}

extension SherpaOfflineCorrector.Kind {
    var needsPunctuation: Bool { self == .paraformer }

    var modelKind: ModelKind {
        switch self {
        case .senseVoice: return .senseVoice
        case .paraformer: return .paraformer
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
        case .appleSpeech: return "系统语音识别"
        case .none: return "不纠错"
        }
    }
}
