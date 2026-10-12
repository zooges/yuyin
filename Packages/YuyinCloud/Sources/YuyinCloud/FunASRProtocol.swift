import Foundation
import YuyinCore

/// Alibaba Cloud Model Studio (DashScope) Fun-ASR endpoints.
/// - Realtime WebSocket: https://help.aliyun.com/zh/model-studio/fun-asr-realtime-websocket-api
/// - Sentence (HTTP, base64 audio): https://help.aliyun.com/zh/model-studio/non-real-time-speech-recognition-for-fun-asr-realtime
public struct FunASRConfig: Sendable, Equatable {
    public var apiKey: String
    public var model: String
    public var webSocketURL: URL
    public var httpURL: URL
    public var requestTimeout: TimeInterval

    public init(
        apiKey: String,
        model: String = "fun-asr-realtime",
        webSocketURL: URL = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!,
        httpURL: URL = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!,
        requestTimeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.webSocketURL = webSocketURL
        self.httpURL = httpURL
        self.requestTimeout = requestTimeout
    }
}

enum FunASRProtocol {
    static func runTask(taskID: String, model: String) -> String {
        json([
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": AudioSpec.sampleRate,
                    "language_hints": ["zh"],
                ] as [String: Any],
                "input": [String: Any](),
            ] as [String: Any],
        ])
    }

    static func finishTask(taskID: String) -> String {
        json([
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [String: Any]()],
        ])
    }

    struct Sentence: Equatable {
        let id: Int
        let text: String
        let isEnd: Bool
    }

    enum Event: Equatable {
        case started
        case result(Sentence)
        case heartbeat
        case finished
        case failed(code: String, message: String)
        case unknown
    }

    static func parseEvent(_ data: Data) -> Event {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let event = header["event"] as? String
        else { return .unknown }
        switch event {
        case "task-started":
            return .started
        case "task-finished":
            return .finished
        case "task-failed":
            return .failed(
                code: header["error_code"] as? String ?? "",
                message: header["error_message"] as? String ?? ""
            )
        case "result-generated":
            guard let payload = root["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any]
            else { return .unknown }
            if sentence["heartbeat"] as? Bool == true { return .heartbeat }
            return .result(Sentence(
                id: sentence["sentence_id"] as? Int ?? 0,
                text: sentence["text"] as? String ?? "",
                isEnd: sentence["sentence_end"] as? Bool ?? false
            ))
        default:
            return .unknown
        }
    }

    /// Maps DashScope error codes / HTTP status to user-facing errors.
    static func error(code: String, message: String, status: Int? = nil) -> ASRError {
        let lowered = code.lowercased()
        if status == 401 || status == 403 || lowered.contains("apikey") || lowered.contains("unauthorized")
            || lowered.contains("accessdenied") {
            return .authenticationFailed
        }
        let detail = [code, message].filter { !$0.isEmpty }.joined(separator: ": ")
        return .server(detail.isEmpty ? "HTTP \(status ?? 0)" : detail)
    }

    // MARK: - HTTP sentence recognition

    static func sentenceRequestBody(wav: Data, model: String) -> Data {
        let body: [String: Any] = [
            "model": model,
            "input": [
                "messages": [
                    ["role": "user", "content": [["audio": "data:audio/wav;base64," + wav.base64EncodedString()]]],
                ],
            ],
            "parameters": ["format": "wav"],
            "resources": [Any](),
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Text from a non-streaming response. Accepts both `output.text` and the sentence form.
    static func parseSentenceResponse(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any]
        else { return nil }
        if let text = output["text"] as? String { return text }
        if let sentence = output["sentence"] as? [String: Any], let text = sentence["text"] as? String { return text }
        if let sentences = output["sentences"] as? [[String: Any]] {
            return sentences.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    static func parseErrorBody(_ data: Data) -> (code: String, message: String) {
        let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (root["code"] as? String ?? "", root["message"] as? String ?? "")
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
