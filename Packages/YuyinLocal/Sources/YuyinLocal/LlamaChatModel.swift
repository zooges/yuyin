#if canImport(llama)
import Foundation
import llama
import YuyinCore

/// A local chat model through llama.cpp (Metal), for 润色: legal transcripts stay on the Mac.
public final class LlamaChatModel: TextGenerating, @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "app.yuyin.llama.chat", qos: .userInitiated)
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    static let contextLength: UInt32 = 8192
    static let batchSize = 2048

    public init(model: String) {
        path = model
    }

    deinit {
        release()
    }

    public func prepare() async throws {
        let path = path
        try await SherpaRuntime.run(on: queue) { [self] in
            guard model == nil else { return }
            try SherpaRuntime.checkFiles([path], model: "润色模型")
            Self.initializeBackend
            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = 999
            guard let model = llama_model_load_from_file(path, modelParams) else {
                throw ASRError.modelMissing("润色模型（文件无法加载，请重新下载）")
            }
            self.model = model
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = Self.contextLength
            contextParams.n_batch = UInt32(Self.batchSize)
            contextParams.no_perf = true
            guard let context = llama_init_from_model(model, contextParams) else {
                release()
                throw ASRError.inferenceFailed("无法创建润色模型的推理上下文")
            }
            self.context = context
            let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            self.sampler = sampler
        }
    }

    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await SherpaRuntime.run(on: queue) { [self] in
            guard let model, let context, let sampler else { throw ASRError.notPrepared }
            let vocab = llama_model_get_vocab(model)
            let prompt = Self.chat(template: llama_model_chat_template(model, nil), system: system, user: user)

            let capacity = prompt.utf8.count + 16
            var tokens = [llama_token](repeating: 0, count: capacity)
            let count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(capacity), true, true)
            guard count > 0, Int(count) + maxTokens < Int(Self.contextLength) else {
                throw ASRError.inferenceFailed("润色内容过长")
            }
            tokens.removeSubrange(Int(count)...)

            llama_memory_clear(llama_get_memory(context), true)
            llama_sampler_reset(sampler)
            var offset = 0
            while offset < tokens.count {
                let length = min(Self.batchSize, tokens.count - offset)
                let status = tokens.withUnsafeMutableBufferPointer {
                    llama_decode(context, llama_batch_get_one($0.baseAddress! + offset, Int32(length)))
                }
                guard status == 0 else { throw ASRError.inferenceFailed("润色模型读入失败（\(status)）") }
                offset += length
            }

            var bytes: [UInt8] = []
            var piece = [CChar](repeating: 0, count: 256)
            for _ in 0..<maxTokens {
                var token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }
                let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
                if length > 0 { bytes += piece[0..<Int(length)].map { UInt8(bitPattern: $0) } }
                let status = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
                guard status == 0 else { break }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in release() }
    }

    /// The model's own chat template (ChatML when it has none).
    static func chat(template: UnsafePointer<CChar>?, system: String, user: String) -> String {
        guard let template else {
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        let parts = [("system", system), ("user", user)].map { (strdup($0.0), strdup($0.1)) }
        defer { parts.forEach { free($0.0); free($0.1) } }
        var messages = parts.map { llama_chat_message(role: $0.0, content: $0.1) }
        var size = (system.utf8.count + user.utf8.count) * 2 + 512
        var buffer = [CChar](repeating: 0, count: size)
        var written = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(size))
        if written > Int32(size) {
            size = Int(written) + 1
            buffer = [CChar](repeating: 0, count: size)
            written = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(size))
        }
        guard written > 0 else {
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        return String(decoding: buffer[0..<Int(written)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static let initializeBackend: Void = llama_backend_init()

    private func release() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
    }
}
#endif
