import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YuyinCore

/// Sentence-level cloud second pass: one closed sentence → WAV → synchronous Fun-ASR HTTP call.
public final class FunASRCorrector: CorrectorASREngine, @unchecked Sendable {
    public let providerID = "funasr-cloud"
    private let config: FunASRConfig
    private let session: URLSession

    public init(config: FunASRConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func prepare() async throws {
        guard !config.apiKey.isEmpty else { throw ASRError.missingAPIKey }
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        guard !samples.isEmpty else { return hint }
        var request = URLRequest(url: config.httpURL, timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = FunASRProtocol.sentenceRequestBody(wav: WAVFile.encode(samples), model: config.model)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ASRError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = FunASRProtocol.parseErrorBody(data)
            throw FunASRProtocol.error(code: body.code, message: body.message, status: status)
        }
        guard let text = FunASRProtocol.parseSentenceResponse(data) else {
            throw ASRError.server("无法解析云端返回")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hint : trimmed
    }

    public func shutdown() async {}
}

public enum CloudEngines {
    public static func makeStreaming(apiKey: String) throws -> any StreamingASREngine {
        let config = FunASRConfig(apiKey: apiKey)
        guard !config.apiKey.isEmpty else { throw ASRError.missingAPIKey }
        return FunASRStreamingEngine(config: config)
    }

    public static func makeCorrector(apiKey: String) throws -> any CorrectorASREngine {
        let config = FunASRConfig(apiKey: apiKey)
        guard !config.apiKey.isEmpty else { throw ASRError.missingAPIKey }
        return FunASRCorrector(config: config)
    }
}
