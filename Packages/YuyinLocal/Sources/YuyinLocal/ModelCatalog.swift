import Foundation
import YuyinCore

public enum ModelKind: String, CaseIterable, Identifiable, Sendable {
    case streamingXASRFast
    case streamingXASR
    case streamingZipformer
    case senseVoiceANE
    case senseVoice
    case paraformer
    case fireRed
    case qwen3ASR
    case qwen3ASRLarge
    case funASRNano
    case punctuation
    case speakerEmbedding
    case speakerSegmentation
    case polishModel

    /// CAM++ (zh/en, 3D-Speaker). On two AMI meetings, live speaker accuracy was 95.7% / 90.1%,
    /// against 92.4% / 81.2% for the ERes2Net model used before; it also separated the speakers
    /// in the user's recordings better (EER 4.9% vs 7.8%) and runs twice as fast.
    public static let speakerEmbeddingFile = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .streamingXASRFast: return "X-ASR 流式 · 低延迟（推荐）"
        case .streamingXASR: return "X-ASR 流式 · 标准"
        case .streamingZipformer: return "流式 Zipformer（中英，旧版）"
        case .senseVoiceANE: return "SenseVoice · 神经网络引擎"
        case .senseVoice: return "SenseVoice · Sherpa"
        case .paraformer: return "Paraformer-large 中文"
        case .fireRed: return "FireRedASR 大模型"
        case .qwen3ASR: return "Qwen3-ASR 0.6B"
        case .qwen3ASRLarge: return "Qwen3-ASR 1.7B（Mac 推荐）"
        case .funASRNano: return "Fun-ASR-Nano"
        case .punctuation: return "中文标点"
        case .speakerEmbedding: return "说话人声纹"
        case .speakerSegmentation: return "说话人分割"
        case .polishModel: return "润色模型 Qwen3-4B"
        }
    }

    public var role: String {
        switch self {
        case .streamingXASRFast: return "实时字幕，每 0.16 秒出字，说完约 0.3 秒上屏；错字比标准版略多（纠错会随后替换）"
        case .streamingXASR: return "实时字幕，自带标点；法律会议录音上错字最少，约 0.5 秒上屏"
        case .streamingZipformer: return "实时字幕"
        case .senseVoiceANE, .senseVoice, .fireRed: return "句末纠错"
        case .paraformer: return "句末纠错，纯中文、速度快（英文句自动交给 SenseVoice），自动配标点"
        case .qwen3ASR: return "句末纠错（大模型，口语场景实测一般）"
        case .qwen3ASRLarge: return "句末纠错，显卡加速；参考上文与专业词汇，法律会议录音上比 Fun-ASR-Nano 更准、快一倍"
        case .funASRNano: return "句末纠错，中文 / 英文 / 中英混说实测最准（大模型）"
        case .punctuation: return "为 Paraformer / FireRed 的结果加标点"
        case .speakerEmbedding: return "标注说话人、重新分析说话人"
        case .speakerSegmentation: return "录音结束后的整场多人分析"
        case .polishModel: return "把转写整理成书面记录（去口头禅、修同音错字），本机运行"
        }
    }

    public var approximateSize: String {
        switch self {
        case .streamingXASRFast, .streamingXASR: return "约 130 MB"
        case .streamingZipformer: return "约 490 MB"
        case .senseVoiceANE: return "约 450 MB"
        case .senseVoice: return "约 160 MB"
        case .paraformer: return "约 225 MB"
        case .fireRed: return "约 1.4 GB"
        case .qwen3ASR: return "约 840 MB"
        case .funASRNano: return "约 800 MB"
        case .qwen3ASRLarge: return "约 2.8 GB"
        case .punctuation: return "约 62 MB"
        case .speakerEmbedding: return "约 28 MB"
        case .speakerSegmentation: return "约 7 MB"
        case .polishModel: return "约 2.5 GB"
        }
    }

    /// Official sherpa-onnx release assets. nil = fetched by FluidAudio from Hugging Face.
    public var remoteURL: URL? {
        let base = "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
        switch self {
        case .streamingXASRFast:
            // https://github.com/Gilgamesh-J/X-ASR (Apache-2.0). 160 ms chunks: text 0.30 s after
            // speech (median) vs 0.48 s for 480 ms chunks, which are a little more accurate.
            return URL(string: base + "asr-models/sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05.tar.bz2")
        case .streamingXASR:
            return URL(string: base + "asr-models/sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05.tar.bz2")
        case .streamingZipformer:
            return URL(string: base + "asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2")
        case .senseVoice:
            return URL(string: base + "asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2")
        case .paraformer:
            return URL(string: base + "asr-models/sherpa-onnx-paraformer-zh-2023-09-14.tar.bz2")
        case .fireRed:
            return URL(string: base + "asr-models/sherpa-onnx-fire-red-asr-large-zh_en-2025-02-16.tar.bz2")
        case .qwen3ASR:
            return URL(string: base + "asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2")
        case .funASRNano:
            return URL(string: base + "asr-models/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2")
        case .punctuation:
            return URL(string: base + "punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2")
        case .speakerEmbedding:
            return URL(string: base + "speaker-recongition-models/" + Self.speakerEmbeddingFile)
        case .speakerSegmentation:
            return URL(string: base + "speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")
        case .senseVoiceANE, .qwen3ASRLarge, .polishModel:
            return nil
        }
    }

    /// Models downloaded as plain files rather than one archive; each file lists mirrors in
    /// the order to try (huggingface.co is unreachable from mainland China).
    public var remoteFiles: [[URL]]? {
        switch self {
        case .qwen3ASRLarge:
            // https://huggingface.co/mradermacher/Qwen3-ASR-1.7B-GGUF (Qwen3-ASR: Apache-2.0)
            return [Self.qwen3LargeModelFile, Self.qwen3LargeProjectorFile].map { name in
                ["https://hf-mirror.com", "https://huggingface.co"].compactMap {
                    URL(string: "\($0)/mradermacher/Qwen3-ASR-1.7B-GGUF/resolve/main/\(name)")
                }
            }
        case .polishModel:
            // https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF (Qwen3: Apache-2.0)
            return [["https://hf-mirror.com", "https://huggingface.co"].compactMap {
                URL(string: "\($0)/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/\(Self.polishModelFile)")
            }]
        default:
            return nil
        }
    }

    static let polishModelFile = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    static let qwen3LargeModelFile = "Qwen3-ASR-1.7B.Q8_0.gguf"
    static let qwen3LargeProjectorFile = "Qwen3-ASR-1.7B.mmproj-f16.gguf"

    /// Directory names are kept from v0.1 so existing installs keep working.
    var directoryName: String {
        switch self {
        case .streamingXASRFast: return "streaming-x-asr-160ms"
        case .streamingXASR: return "streaming-x-asr-zh-en"
        case .streamingZipformer: return "streaming-zipformer-zh-en"
        case .senseVoice: return "sensevoice-small"
        case .paraformer: return "paraformer-zh"
        case .fireRed: return "firered-asr-large"
        case .qwen3ASR: return "qwen3-asr-0.6b"
        case .funASRNano: return "funasr-nano"
        case .qwen3ASRLarge: return "qwen3-asr-1.7b-gguf"
        case .polishModel: return "polish-qwen3-4b"
        case .punctuation: return "punctuation-zh-en"
        case .speakerEmbedding: return "speaker-embedding"
        case .speakerSegmentation: return "speaker-segmentation"
        // FluidAudio's `Repo.senseVoiceSmall.folderName`.
        case .senseVoiceANE: return "sensevoice-small"
        }
    }
}

public struct StreamingModelFiles: Sendable, Equatable {
    public let encoder: String
    public let decoder: String
    public let joiner: String
    public let tokens: String
}

public struct OfflineModelFiles: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        case single(model: String)
        case encoderDecoder(encoder: String, decoder: String)
        case qwen3(convFrontend: String, encoder: String, decoder: String, tokenizer: String)
        case funASRNano(encoderAdaptor: String, llm: String, embedding: String, tokenizer: String)
    }

    public let layout: Layout
    public let tokens: String
}

/// Where models live and which files make a complete install.
public struct ModelLocator: Sendable {
    /// `Application Support/Yuyin/Models`
    public let root: URL
    /// FluidAudio's own cache (`Application Support/FluidAudio/Models`).
    public let fluidRoot: URL

    public init(root: URL, fluidRoot: URL) {
        self.root = root
        self.fluidRoot = fluidRoot
    }

    public static var standard: ModelLocator {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ModelLocator(
            root: support.appendingPathComponent("Yuyin/Models", isDirectory: true),
            fluidRoot: support.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        )
    }

    public func directory(for kind: ModelKind) -> URL {
        switch kind {
        case .senseVoiceANE: return fluidRoot.appendingPathComponent(kind.directoryName, isDirectory: true)
        default: return root.appendingPathComponent(kind.directoryName, isDirectory: true)
        }
    }

    /// Installed, but an older model than the one we now download (speaker embedding before v0.8).
    public func isOutdated(_ kind: ModelKind) -> Bool {
        kind == .speakerEmbedding && isInstalled(kind)
            && Self.find(in: directory(for: kind), exact: ModelKind.speakerEmbeddingFile) == nil
    }

    public func isInstalled(_ kind: ModelKind) -> Bool {
        switch kind {
        case .senseVoiceANE:
            return FluidSenseVoiceCorrector.modelsExist(at: directory(for: kind))
        case .streamingXASRFast, .streamingXASR, .streamingZipformer:
            return (try? streamingFiles(in: directory(for: kind))) != nil
        case .qwen3ASRLarge:
            return (try? ggufFiles(in: directory(for: kind))) != nil
        case .polishModel:
            return (try? polishModelFile()) != nil
        case .senseVoice, .paraformer, .fireRed, .qwen3ASR, .funASRNano:
            return (try? offlineFiles(kind, in: directory(for: kind))) != nil
        case .speakerEmbedding, .speakerSegmentation, .punctuation:
            return (try? singleModel(kind, in: directory(for: kind))) != nil
        }
    }

    // MARK: - File resolution (also used to validate staged / imported folders)

    /// The chat model for 润色 (one GGUF file).
    public func polishModelFile(in dir: URL? = nil) throws -> String {
        let dir = dir ?? directory(for: .polishModel)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = files.filter({ $0.hasSuffix(".gguf") }).sorted().first,
              ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0) > 100_000_000
        else { throw ASRError.modelMissing(ModelKind.polishModel.title) }
        return dir.appendingPathComponent(name).path
    }

    /// A llama.cpp model and its audio projector ("*mmproj*.gguf").
    public func ggufFiles(in dir: URL? = nil) throws -> (model: String, projector: String) {
        let dir = dir ?? directory(for: .qwen3ASRLarge)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let ggufs = files.filter { $0.hasSuffix(".gguf") }.sorted()
        func complete(_ name: String) -> Bool {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            return size > 1_000_000
        }
        guard let projector = ggufs.first(where: { $0.lowercased().contains("mmproj") && complete($0) }),
              let model = ggufs.first(where: { !$0.lowercased().contains("mmproj") && complete($0) })
        else { throw ASRError.modelMissing(ModelKind.qwen3ASRLarge.title) }
        return (dir.appendingPathComponent(model).path, dir.appendingPathComponent(projector).path)
    }

    public func streamingFiles(in dir: URL? = nil) throws -> StreamingModelFiles {
        let dir = dir ?? directory(for: .streamingZipformer)
        let missing = ASRError.modelMissing(ModelKind.streamingZipformer.title)
        guard let tokens = Self.find(in: dir, exact: "tokens.txt"),
              let encoder = Self.find(in: dir, prefix: "encoder", preferInt8: true),
              let decoder = Self.find(in: dir, prefix: "decoder", preferInt8: false),
              let joiner = Self.find(in: dir, prefix: "joiner", preferInt8: true)
        else { throw missing }
        return StreamingModelFiles(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
    }

    public func offlineFiles(_ kind: ModelKind, in dir: URL? = nil) throws -> OfflineModelFiles {
        let dir = dir ?? directory(for: kind)
        let missing = ASRError.modelMissing(kind.title)
        // LLM-based models ship a tokenizer directory instead of tokens.txt.
        switch kind {
        case .qwen3ASR:
            guard let conv = Self.find(in: dir, exact: "conv_frontend.onnx"),
                  let encoder = Self.find(in: dir, exact: "encoder.int8.onnx"),
                  let decoder = Self.find(in: dir, exact: "decoder.int8.onnx"),
                  let tokenizer = Self.findDirectory(in: dir, named: "tokenizer")
            else { throw missing }
            return OfflineModelFiles(layout: .qwen3(convFrontend: conv, encoder: encoder, decoder: decoder, tokenizer: tokenizer), tokens: "")
        case .funASRNano:
            guard let adaptor = Self.find(in: dir, exact: "encoder_adaptor.int8.onnx"),
                  let llm = Self.find(in: dir, exact: "llm.int8.onnx"),
                  let embedding = Self.find(in: dir, exact: "embedding.int8.onnx"),
                  let tokenizer = Self.findDirectory(in: dir, named: "Qwen3-0.6B")
            else { throw missing }
            return OfflineModelFiles(layout: .funASRNano(encoderAdaptor: adaptor, llm: llm, embedding: embedding, tokenizer: tokenizer), tokens: "")
        default:
            break
        }
        guard let tokens = Self.find(in: dir, exact: "tokens.txt") else { throw missing }
        switch kind {
        case .fireRed:
            guard let encoder = Self.find(in: dir, exact: "encoder.int8.onnx"),
                  let decoder = Self.find(in: dir, exact: "decoder.int8.onnx")
            else { throw missing }
            return OfflineModelFiles(layout: .encoderDecoder(encoder: encoder, decoder: decoder), tokens: tokens)
        case .senseVoice, .paraformer:
            guard let model = Self.find(in: dir, prefix: "model", preferInt8: true) else { throw missing }
            return OfflineModelFiles(layout: .single(model: model), tokens: tokens)
        default:
            throw missing
        }
    }

    public func singleModel(_ kind: ModelKind, in dir: URL? = nil) throws -> String {
        let dir = dir ?? directory(for: kind)
        if kind == .speakerEmbedding, let current = Self.find(in: dir, exact: ModelKind.speakerEmbeddingFile) {
            return current
        }
        guard let model = Self.find(in: dir, prefix: "", preferInt8: false) else {
            throw ASRError.modelMissing(kind.title)
        }
        return model
    }

    /// Searches `dir` and its immediate subdirectories (archives often nest one level).
    static func find(in dir: URL, exact name: String) -> String? {
        candidates(in: dir).first { $0.lastPathComponent == name }?.path
    }

    static func findDirectory(in dir: URL, named name: String) -> String? {
        let fm = FileManager.default
        for base in [dir] + ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []) {
            let candidate = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { return candidate.path }
        }
        return nil
    }

    static func find(in dir: URL, prefix: String, preferInt8: Bool) -> String? {
        let matches = candidates(in: dir)
            .filter { $0.pathExtension == "onnx" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let int8 = matches.filter { $0.lastPathComponent.contains(".int8.") }
        let full = matches.filter { !$0.lastPathComponent.contains(".int8.") }
        return (preferInt8 ? int8.first ?? full.first : full.first ?? int8.first)?.path
    }

    private static func candidates(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        var out: [URL] = []
        var subdirs: [URL] = []
        for url in top {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subdirs.append(url)
            } else {
                out.append(url)
            }
        }
        for sub in subdirs where !sub.lastPathComponent.hasPrefix("test") {
            let files = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            out.append(contentsOf: files)
        }
        return out
    }
}
