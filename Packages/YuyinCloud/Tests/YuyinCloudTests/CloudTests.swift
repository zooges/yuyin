import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YuyinCore
@testable import YuyinCloud

/// Scripted DashScope server.
final class FakeSocket: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [WebSocketMessage] = []
    private let inbox: AsyncThrowingStream<WebSocketMessage, Error>
    private let push: AsyncThrowingStream<WebSocketMessage, Error>.Continuation
    var respondToRunTask: String? = #"{"header":{"event":"task-started","task_id":"t"},"payload":{}}"#
    private(set) var request: URLRequest?

    init() {
        (inbox, push) = AsyncThrowingStream.makeStream(of: WebSocketMessage.self)
    }

    var sentMessages: [WebSocketMessage] { lock.withLock { sent } }

    var sentJSON: [[String: Any]] {
        sentMessages.compactMap {
            guard case .text(let t) = $0 else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
        }
    }

    func connect(_ request: URLRequest) -> FakeSocket {
        self.request = request
        return self
    }

    func serverSends(_ json: String) { push.yield(.text(json)) }

    func send(_ message: WebSocketMessage) async throws {
        lock.withLock { sent.append(message) }
        if case .text(let text) = message {
            if text.contains("run-task"), let reply = respondToRunTask { push.yield(.text(reply)) }
            if text.contains("finish-task") { push.yield(.text(#"{"header":{"event":"task-finished"},"payload":{}}"#)) }
        }
    }

    func receive() async throws -> WebSocketMessage {
        for try await m in inbox { return m }
        throw URLError(.networkConnectionLost)
    }

    func close() { push.finish() }
}

private func result(id: Int, text: String, end: Bool) -> String {
    #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":\#(id),"text":"\#(text)","sentence_end":\#(end),"heartbeat":false}}}}"#
}

final class CloudTests: XCTestCase {
    private let chunk = [Float](repeating: 0.1, count: 1600)

    private func engine(_ socket: FakeSocket, key: String = "sk-test", timeout: TimeInterval = 2) -> FunASRStreamingEngine {
        FunASRStreamingEngine(config: FunASRConfig(apiKey: key), connect: { socket.connect($0) }, startTimeout: timeout)
    }

    func testRunTaskHandshakeAndHeaders() async throws {
        let socket = FakeSocket()
        let e = engine(socket)
        try await e.prepare()
        XCTAssertEqual(socket.request?.value(forHTTPHeaderField: "Authorization"), "bearer sk-test")
        let run = try XCTUnwrap(socket.sentJSON.first)
        let header = run["header"] as? [String: Any]
        let payload = run["payload"] as? [String: Any]
        let params = payload?["parameters"] as? [String: Any]
        XCTAssertEqual(header?["action"] as? String, "run-task")
        XCTAssertEqual(header?["streaming"] as? String, "duplex")
        XCTAssertEqual(payload?["model"] as? String, "fun-asr-realtime")
        XCTAssertEqual(params?["format"] as? String, "pcm")
        XCTAssertEqual(params?["sample_rate"] as? Int, 16_000)
        XCTAssertNotNil(payload?["input"] as? [String: Any])

        await e.shutdown()
        let finish = try XCTUnwrap(socket.sentJSON.last)
        XCTAssertEqual((finish["header"] as? [String: Any])?["action"] as? String, "finish-task")
        XCTAssertEqual((finish["header"] as? [String: Any])?["task_id"] as? String, header?["task_id"] as? String)
    }

    func testSentencesPartialsEndpointAndNoBleedAfterClose() async throws {
        let socket = FakeSocket()
        let e = engine(socket)
        try await e.prepare()
        func server(_ messages: String...) async throws {
            for m in messages { socket.serverSends(m) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        try await server(result(id: 1, text: "今天", end: false))
        var u = try await e.accept(chunk)
        XCTAssertEqual(u, StreamingUpdate(text: "今天", isEndpoint: false))

        try await server(result(id: 1, text: "今天开会。", end: true))
        u = try await e.accept(chunk)
        XCTAssertEqual(u, StreamingUpdate(text: "今天开会。", isEndpoint: true))
        let first = await e.finishUtterance()
        XCTAssertEqual(first, "今天开会。")

        try await server(result(id: 2, text: "下午", end: false))
        u = try await e.accept(chunk)
        XCTAssertEqual(u, StreamingUpdate(text: "下午", isEndpoint: false))
        // Local VAD closes the utterance while the cloud sentence is still open.
        let second = await e.finishUtterance()
        XCTAssertEqual(second, "下午")

        try await server(result(id: 2, text: "下午三点。", end: true), result(id: 3, text: "好的", end: false))
        u = try await e.accept(chunk)
        XCTAssertEqual(u, StreamingUpdate(text: "好的", isEndpoint: false), "late result for closed sentence 2 is ignored")
        XCTAssertEqual(socket.sentMessages.filter { if case .data = $0 { return true } else { return false } }.count, 4)
        await e.shutdown()
    }

    func testReconnectResetsSentenceNumbering() async throws {
        let sockets = [FakeSocket(), FakeSocket()]
        let lock = NSLock()
        var next = 0
        let e = FunASRStreamingEngine(config: FunASRConfig(apiKey: "k"), connect: { request in
            lock.withLock {
                defer { next += 1 }
                return sockets[min(next, sockets.count - 1)].connect(request)
            }
        }, startTimeout: 2)
        try await e.prepare()
        sockets[0].serverSends(result(id: 7, text: "第七句。", end: true))
        try await Task.sleep(nanoseconds: 30_000_000)
        _ = try await e.accept(chunk)
        let closed = await e.finishUtterance()
        XCTAssertEqual(closed, "第七句。")

        // Server drops the idle task (e.g. a long pause): the socket closes.
        sockets[0].close()
        try await Task.sleep(nanoseconds: 30_000_000)
        // Next audio transparently opens a new task on a new socket…
        _ = try await e.accept(chunk)
        // …whose sentence ids start again from 1 and must not be filtered out.
        sockets[1].serverSends(result(id: 1, text: "新任务第一句", end: false))
        try await Task.sleep(nanoseconds: 30_000_000)
        let u = try await e.accept(chunk)
        XCTAssertEqual(u.text, "新任务第一句")
        XCTAssertEqual(sockets[1].sentJSON.first.flatMap { ($0["header"] as? [String: Any])?["action"] as? String }, "run-task")
        await e.shutdown()
    }

    func testInvalidKeyMapsToAuthenticationError() async {
        let socket = FakeSocket()
        socket.respondToRunTask = #"{"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"Invalid API-key provided."},"payload":{}}"#
        let e = engine(socket)
        do {
            try await e.prepare()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ASRError, .authenticationFailed)
        }
    }

    func testStartTimesOut() async {
        let socket = FakeSocket()
        socket.respondToRunTask = nil
        let e = engine(socket, timeout: 0.2)
        do {
            try await e.prepare()
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? ASRError, .network("连接云端超时"))
        }
    }

    func testMissingKeyFailsFastWithoutMocks() {
        XCTAssertThrowsError(try CloudEngines.makeStreaming(apiKey: "  ")) {
            XCTAssertEqual($0 as? ASRError, .missingAPIKey)
        }
        XCTAssertThrowsError(try CloudEngines.makeCorrector(apiKey: ""))
    }

    func testProtocolParsing() {
        XCTAssertEqual(FunASRProtocol.parseEvent(Data(result(id: 4, text: "你好", end: true).utf8)),
                       .result(.init(id: 4, text: "你好", isEnd: true)))
        let heartbeat = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"heartbeat":true,"text":""}}}}"#
        XCTAssertEqual(FunASRProtocol.parseEvent(Data(heartbeat.utf8)), .heartbeat)
        XCTAssertEqual(FunASRProtocol.parseSentenceResponse(Data(#"{"output":{"text":"甲乙"}}"#.utf8)), "甲乙")
        XCTAssertEqual(FunASRProtocol.parseSentenceResponse(Data(#"{"output":{"sentence":{"text":"丙"}}}"#.utf8)), "丙")
        XCTAssertEqual(FunASRProtocol.error(code: "Throttling", message: "slow down", status: 429), .server("Throttling: slow down"))
    }
}

// MARK: - HTTP corrector

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CorrectorTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testSentenceRequestAndResponse() async throws {
        var seen: URLRequest?
        StubProtocol.handler = { req in
            seen = req
            return (200, Data(#"{"output":{"text":"云端结果。","sentence":{"sentence_end":true}},"request_id":"r"}"#.utf8))
        }
        let c = FunASRCorrector(config: FunASRConfig(apiKey: "sk-1"), session: session())
        try await c.prepare()
        let samples = [Float](repeating: 0.05, count: 3200)
        let text = try await c.correct(samples, hint: "提示")
        XCTAssertEqual(text, "云端结果。")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable")
        XCTAssertTrue(seen?.url?.absoluteString.hasSuffix("/multimodal-generation/generation") == true)

        let body = try XCTUnwrap(StubProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "fun-asr-realtime")
        let messages = (json["input"] as? [String: Any])?["messages"] as? [[String: Any]]
        let audio = ((messages?.first?["content"] as? [[String: Any]])?.first?["audio"] as? String) ?? ""
        XCTAssertTrue(audio.hasPrefix("data:audio/wav;base64,"))
        let wav = Data(base64Encoded: String(audio.dropFirst("data:audio/wav;base64,".count)))
        XCTAssertEqual(wav?.count, 44 + 3200 * 2)
        XCTAssertEqual(wav.map { String(decoding: $0.prefix(4), as: UTF8.self) }, "RIFF")
    }

    func testUnauthorizedAndEmptyResult() async throws {
        StubProtocol.handler = { _ in (401, Data(#"{"code":"InvalidApiKey","message":"Invalid API-key provided."}"#.utf8)) }
        let c = FunASRCorrector(config: FunASRConfig(apiKey: "bad"), session: session())
        do {
            _ = try await c.correct([0.1, 0.2], hint: "")
            XCTFail("expected auth failure")
        } catch {
            XCTAssertEqual(error as? ASRError, .authenticationFailed)
        }

        StubProtocol.handler = { _ in (200, Data(#"{"output":{"text":""}}"#.utf8)) }
        let text = try await c.correct([0.1, 0.2], hint: "流式文本")
        XCTAssertEqual(text, "流式文本")
    }

    func testQwenMTRequestAndResponse() async throws {
        var seen: URLRequest?
        StubProtocol.handler = { req in
            seen = req
            return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":" Good morning. "}}]}"#.utf8))
        }
        let t = QwenMTTranslator(apiKey: "sk-9", session: session())
        try await t.prepare()
        let out = try await t.translate("早上好。", from: .zh, to: .en)
        XCTAssertEqual(out, "Good morning.")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-9")
        XCTAssertTrue(seen?.url?.absoluteString.hasSuffix("/compatible-mode/v1/chat/completions") == true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen-mt-flash")
        let options = json["translation_options"] as? [String: Any]
        XCTAssertEqual(options?["source_lang"] as? String, "zh")
        XCTAssertEqual(options?["target_lang"] as? String, "en")
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")

        StubProtocol.handler = { _ in (401, Data(#"{"error":{"code":"invalid_api_key","message":"Incorrect API key"}}"#.utf8)) }
        do {
            _ = try await t.translate("你好", from: .zh, to: .en)
            XCTFail("expected auth error")
        } catch {
            XCTAssertEqual(error as? ASRError, .authenticationFailed)
        }
    }
}
