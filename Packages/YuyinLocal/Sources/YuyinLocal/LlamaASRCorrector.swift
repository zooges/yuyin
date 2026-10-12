#if canImport(llama)
import Foundation
import llama
import YuyinCore

/// Qwen3-ASR 1.7B through llama.cpp, on the GPU (Metal). The approach of CapsWriter-Offline,
/// whose Chinese accuracy the user singled out. On the user's legal meeting it beat Fun-ASR-Nano
/// ("逾期" vs "语气", "意思表示" vs "历史表", far more names right) at ~0.3 s per sentence.
///
/// Each sentence gets a system prompt with context: the domain, the expected terms and the
/// sentences just before it. The model reads it like a human transcriber would, which kept a
/// party's name right across the meeting once it had been heard right.
public final class LlamaASRCorrector: CorrectorASREngine, @unchecked Sendable {
    public let providerID = "llama-qwen3-asr-1.7b"

    private let modelPath: String
    private let projectorPath: String
    /// Domain and terms, the fixed part of every prompt; nil = no context.
    private let background: String?
    private let queue = DispatchQueue(label: "app.yuyin.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    /// The latest finished text, as context for the next sentence.
    private var recent = ""

    /// Characters of earlier text the next sentence sees.
    static let recentLength = 80
    static let maxTokens = 400

    public init(model: String, projector: String, background: String?) {
        modelPath = model
        projectorPath = projector
        self.background = background
    }

    deinit {
        release()
    }

    public func prepare() async throws {
        let modelPath = modelPath, projectorPath = projectorPath
        try await SherpaRuntime.run(on: queue) { [self] in
            try SherpaRuntime.checkFiles([modelPath, projectorPath], model: "Qwen3-ASR 1.7B")
            Self.initializeBackend
            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = 999
            guard let model = llama_model_load_from_file(modelPath, modelParams) else {
                throw ASRError.modelMissing("Qwen3-ASR 1.7B（模型文件无法加载，请重新下载）")
            }
            self.model = model
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = 4096
            contextParams.n_batch = 2048
            contextParams.no_perf = true
            guard let context = llama_init_from_model(model, contextParams) else {
                release()
                throw ASRError.inferenceFailed("无法创建 Qwen3-ASR 推理上下文")
            }
            self.context = context
            var mediaParams = mtmd_context_params_default()
            mediaParams.use_gpu = true
            mediaParams.print_timings = false
            mediaParams.n_threads = Int32(SherpaRuntime.threads)
            guard let media = mtmd_init_from_file(projectorPath, model, mediaParams), mtmd_support_audio(media) else {
                release()
                throw ASRError.modelMissing("Qwen3-ASR 1.7B 音频编码器")
            }
            self.media = media
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            self.sampler = sampler
            recent = ""
        }
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        guard !samples.isEmpty else { return hint }
        return try await SherpaRuntime.run(on: queue) { [self] in
            guard let model, let context, let media, let sampler else { throw ASRError.notPrepared }
            let prompt = Self.prompt(system: systemPrompt)

            let bitmap = samples.withUnsafeBufferPointer { mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }
            defer { mtmd_bitmap_free(bitmap) }
            let chunks = mtmd_input_chunks_init()
            defer { mtmd_input_chunks_free(chunks) }
            let tokenized: Int32 = prompt.withCString { text in
                var input = mtmd_input_text(text: text, text_len: strlen(text), add_special: true, parse_special: true)
                var bitmaps: [OpaquePointer?] = [bitmap]
                return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(media, chunks, &input, $0.baseAddress, 1) }
            }
            guard tokenized == 0 else { throw ASRError.inferenceFailed("Qwen3-ASR 输入处理失败（\(tokenized)）") }

            llama_memory_clear(llama_get_memory(context), true)
            llama_sampler_reset(sampler)
            var past: llama_pos = 0
            guard mtmd_helper_eval_chunks(media, context, chunks, 0, 0, 2048, true, &past) == 0 else {
                throw ASRError.inferenceFailed("Qwen3-ASR 音频编码失败")
            }

            let vocab = llama_model_get_vocab(model)
            var bytes: [UInt8] = []
            var piece = [CChar](repeating: 0, count: 256)
            for _ in 0..<Self.maxTokens {
                var token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }
                let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
                if count > 0 { bytes += piece[0..<Int(count)].map { UInt8(bitPattern: $0) } }
                let decoded = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
                guard decoded == 0 else { break }
            }
            let text = Self.transcript(String(decoding: bytes, as: UTF8.self))
            if !text.isEmpty { recent = String((recent + text).suffix(Self.recentLength)) }
            return text.isEmpty ? hint : text
        }
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in release() }
    }

    // MARK: - Prompt

    private var systemPrompt: String? {
        var parts: [String] = []
        if let background { parts.append(background) }
        if !recent.isEmpty { parts.append("上文：" + recent) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Qwen3-ASR's chat format as llama-server builds it; the marker becomes the audio.
    static func prompt(system: String?) -> String {
        let marker = String(cString: mtmd_default_marker())
        let head = system.map { "<|im_start|>system\n\($0)<|im_end|>\n" } ?? ""
        return head + "<|im_start|>user\n\(marker)<|im_end|>\n<|im_start|>assistant\n"
    }

    /// "language Chinese<asr_text>…" → "…".
    static func transcript(_ output: String) -> String {
        let text = output.range(of: "<asr_text>").map { String(output[$0.upperBound...]) } ?? output
        return text.replacingOccurrences(of: "<|im_end|>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lifecycle

    private static let initializeBackend: Void = llama_backend_init()

    private func release() {
        if let sampler { llama_sampler_free(sampler) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        media = nil
        context = nil
        model = nil
    }
}
#endif
