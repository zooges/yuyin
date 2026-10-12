import Foundation
import SherpaOnnx
import YuyinCore

/// sherpa-onnx objects are not thread-safe; each engine owns a serial queue and only
/// touches its recognizer there. That is what makes `@unchecked Sendable` sound.
enum SherpaRuntime {
    static var threads: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    static func run<T>(on queue: DispatchQueue, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try body() })
            }
        }
    }

    /// sherpa-onnx aborts the process (`fatalError` / null pointer) on unreadable models,
    /// so verify files up front and surface a recoverable error instead.
    static func checkFiles(_ paths: [String], model: String) throws {
        for path in paths {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard size > 1024 || path.hasSuffix(".txt") && size > 0 else {
                throw ASRError.modelMissing("\(model)（文件损坏或不完整，请重新下载）")
            }
        }
    }

    static func run<T>(on queue: DispatchQueue, _ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: body()) }
        }
    }
}

/// Streaming transducer, configured like k2-fsa `ios-swiftui/SherpaOnnx2Pass`.
public final class SherpaStreamingEngine: StreamingASREngine, @unchecked Sendable {
    public let providerID: String
    private let files: StreamingModelFiles
    private let queue = DispatchQueue(label: "app.yuyin.sherpa.streaming", qos: .userInitiated)
    private var recognizer: SherpaOnnxRecognizer?

    public init(files: StreamingModelFiles, providerID: String = "sherpa-x-asr") {
        self.files = files
        self.providerID = providerID
    }

    public func prepare() async throws {
        let files = files
        try await SherpaRuntime.run(on: queue) { [self] in
            try SherpaRuntime.checkFiles(
                [files.encoder, files.decoder, files.joiner, files.tokens], model: providerID
            )
            let modelConfig = sherpaOnnxOnlineModelConfig(
                tokens: files.tokens,
                transducer: sherpaOnnxOnlineTransducerModelConfig(
                    encoder: files.encoder,
                    decoder: files.decoder,
                    joiner: files.joiner
                ),
                numThreads: SherpaRuntime.threads,
                modelType: ""
            )
            var config = sherpaOnnxOnlineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(sampleRate: AudioSpec.sampleRate, featureDim: 80),
                modelConfig: modelConfig,
                // The session's VAD normally closes sentences first; these rules are a backstop.
                enableEndpoint: true,
                rule1MinTrailingSilence: 2.4,
                rule2MinTrailingSilence: 1.0,
                rule3MinUtteranceLength: 30,
                decodingMethod: "greedy_search",
                maxActivePaths: 4
            )
            recognizer = SherpaOnnxRecognizer(config: &config)
        }
    }

    public func accept(_ samples: [Float]) async throws -> StreamingUpdate {
        try await SherpaRuntime.run(on: queue) { [self] in
            guard let recognizer else { throw ASRError.notPrepared }
            recognizer.acceptWaveform(samples: samples, sampleRate: AudioSpec.sampleRate)
            while recognizer.isReady() {
                recognizer.decode()
            }
            let result = recognizer.getResult()
            let pairs = zip(result.tokens, result.timestamps)
            let marks = pairs.filter { token, _ in token.contains(where: Self.clauseMarks.contains) }.map { Double($0.1) }
            let ends = pairs.filter { token, _ in token.contains(where: Self.sentenceMarks.contains) }.map { Double($0.1) }
            return StreamingUpdate(text: result.text, isEndpoint: recognizer.isEndpoint(), clauseEnds: marks,
                                   sentenceEnds: ends, heardUntil: result.timestamps.last.map(Double.init))
        }
    }

    public func finishUtterance() async -> String {
        await SherpaRuntime.run(on: queue) { [self] in
            guard let recognizer else { return "" }
            let text = recognizer.getResult().text
            recognizer.reset()
            return text
        }
    }

    static let clauseMarks: Set<Character> = ["，", "。", "？", "！", "；", ",", ".", "?", "!", ";"]
    static let sentenceMarks: Set<Character> = ["。", "？", "！", "?", "!"]

    public func finishUtterance(keepingUntil seconds: Double) async -> String {
        await SherpaRuntime.run(on: queue) { [self] in
            guard let recognizer else { return "" }
            let result = recognizer.getResult()
            let tokens = result.tokens, times = result.timestamps
            recognizer.reset()
            // Token times count from the last reset, like `seconds`.
            guard tokens.count == times.count else { return result.text }
            let kept = zip(tokens, times).prefix { Double($0.1) < seconds }.map(\.0)
            return kept.count == tokens.count ? result.text : Self.text(of: kept)
        }
    }

    /// BPE tokens as sherpa writes them: "▁" starts a word; no spaces next to Chinese.
    static func text(of tokens: [String]) -> String {
        TextFilter.tightenChineseSpacing(tokens.joined().replacingOccurrences(of: "▁", with: " "))
            .trimmingCharacters(in: .whitespaces)
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in recognizer = nil }
    }
}

/// Offline second pass (SenseVoice / Paraformer), as in SherpaOnnx2Pass.
public final class SherpaOfflineCorrector: CorrectorASREngine, @unchecked Sendable {
    public enum Kind: String, Sendable {
        case senseVoice
        case paraformer
    }

    public let providerID: String
    private let kind: Kind
    private let files: OfflineModelFiles
    private let queue = DispatchQueue(label: "app.yuyin.sherpa.offline", qos: .userInitiated)
    private var recognizer: SherpaOnnxOfflineRecognizer?

    /// CT-Transformer punctuation for models that output none (Paraformer).
    private let punctuationModel: String?
    private var punctuation: SherpaOnnxOfflinePunctuationWrapper?

    /// SenseVoice language: "zh" (best for short Mandarin), "en", or "auto".
    private let language: String

    public init(kind: Kind, files: OfflineModelFiles, punctuationModel: String? = nil, language: String = "zh") {
        self.kind = kind
        self.files = files
        self.language = language
        self.punctuationModel = punctuationModel
        switch kind {
        case .senseVoice: providerID = language == "zh" ? "sherpa-sensevoice" : "sherpa-sensevoice-\(language)"
        case .paraformer: providerID = "sherpa-paraformer"
        }
    }

    public func prepare() async throws {
        let kind = kind
        let files = files
        let language = language
        try await SherpaRuntime.run(on: queue) { [self] in
            // The C config structs are not re-exported by the SherpaOnnx module, so each
            // branch builds its recognizer with inferred types (as in swift-api-examples).
            guard case .single(let model) = files.layout else { throw ASRError.modelMissing(kind.rawValue) }
            try SherpaRuntime.checkFiles([model, files.tokens], model: providerID)
            let feat = sherpaOnnxFeatureConfig(sampleRate: AudioSpec.sampleRate, featureDim: 80)
            switch kind {
            case .senseVoice:
                let modelConfig = sherpaOnnxOfflineModelConfig(
                    tokens: files.tokens,
                    numThreads: SherpaRuntime.threads,
                    senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(
                        model: model,
                        language: language,
                        useInverseTextNormalization: true
                    )
                )
                var config = sherpaOnnxOfflineRecognizerConfig(featConfig: feat, modelConfig: modelConfig)
                recognizer = SherpaOnnxOfflineRecognizer(config: &config)
            case .paraformer:
                let modelConfig = sherpaOnnxOfflineModelConfig(
                    tokens: files.tokens,
                    paraformer: sherpaOnnxOfflineParaformerModelConfig(model: model),
                    numThreads: SherpaRuntime.threads,
                    modelType: "paraformer"
                )
                var config = sherpaOnnxOfflineRecognizerConfig(featConfig: feat, modelConfig: modelConfig)
                recognizer = SherpaOnnxOfflineRecognizer(config: &config)
            }
            if let model = punctuationModel, (try? SherpaRuntime.checkFiles([model], model: "punctuation")) != nil {
                var config = sherpaOnnxOfflinePunctuationConfig(
                    model: sherpaOnnxOfflinePunctuationModelConfig(ctTransformer: model, numThreads: 1)
                )
                punctuation = SherpaOnnxOfflinePunctuationWrapper(config: &config)
            }
        }
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        guard !samples.isEmpty else { return hint }
        return try await SherpaRuntime.run(on: queue) { [self] in
            guard let recognizer else { throw ASRError.notPrepared }
            var text = recognizer.decode(samples: samples, sampleRate: AudioSpec.sampleRate).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let punctuation, !text.isEmpty, !text.contains(where: { "，。？！、；：".contains($0) }) {
                text = punctuation.addPunct(text: text)
            }
            return text.isEmpty ? hint : text
        }
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in
            recognizer = nil
            punctuation = nil
        }
    }
}
