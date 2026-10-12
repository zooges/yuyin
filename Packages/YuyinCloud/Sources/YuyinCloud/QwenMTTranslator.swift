import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YuyinCore

/// Qwen-MT sentence translation over DashScope's OpenAI-compatible endpoint.
/// https://help.aliyun.com/zh/model-studio/machine-translation
public final class QwenMTTranslator: TextTranslator, @unchecked Sendable {
    public let providerID = "qwen-mt"
    private let apiKey: String
    private let model: String
    private let url: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "qwen-mt-flash",
        url: URL = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.url = url
        self.session = session
    }

    public func prepare() async throws {
        guard !apiKey.isEmpty else { throw ASRError.missingAPIKey }
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.body(text: text, source: source, target: target, model: model)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ASRError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let error = root["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? (root["code"] as? String) ?? ""
            let message = (error?["message"] as? String) ?? (root["message"] as? String) ?? ""
            throw FunASRProtocol.error(code: code, message: message, status: status)
        }
        guard let text = Self.parse(data) else { throw ASRError.server("无法解析翻译结果") }
        return text
    }

    public func shutdown() async {}

    static func body(text: String, source: Language, target: Language, model: String) -> Data {
        let object: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": text]],
            "translation_options": ["source_lang": source.rawValue, "target_lang": target.rawValue],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func parse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension CloudEngines {
    public static func makeTranslator(apiKey: String) throws -> any TextTranslator {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ASRError.missingAPIKey }
        return QwenMTTranslator(apiKey: apiKey)
    }
}
