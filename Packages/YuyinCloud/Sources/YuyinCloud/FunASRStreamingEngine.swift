import Foundation
import YuyinCore

/// Fun-ASR realtime over WebSocket: run-task → task-started → binary PCM → finish-task.
///
/// Sentence bookkeeping: the cloud numbers sentences (`sentence_id`). When the session
/// closes an utterance, every sentence seen so far belongs to it; later results for those
/// ids are ignored so text never bleeds into the next utterance.
public actor FunASRStreamingEngine: StreamingASREngine {
    public nonisolated let providerID = "funasr-realtime"

    private let config: FunASRConfig
    private let connect: WebSocketConnector
    private let startTimeout: TimeInterval

    private var transport: (any WebSocketTransport)?
    private var taskID = ""
    private var isStarted = false
    private var isFinished = false
    private var isShuttingDown = false
    private var failure: ASRError?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var lastReconnect = Date.distantPast

    private var closedThrough = 0
    private var endedSentences: [Int: String] = [:]
    private var openSentence: (id: Int, text: String)?
    private var endpointPending = false

    public init(
        config: FunASRConfig,
        connect: @escaping WebSocketConnector = URLSessionWebSocketTransport.connector,
        startTimeout: TimeInterval = 10
    ) {
        self.config = config
        self.connect = connect
        self.startTimeout = startTimeout
    }

    public func prepare() async throws {
        guard !config.apiKey.isEmpty else { throw ASRError.missingAPIKey }
        try await openTask()
    }

    public func accept(_ samples: [Float]) async throws -> StreamingUpdate {
        if let failure {
            // The server drops idle tasks (e.g. while paused); reconnect, but not in a tight loop.
            guard failure != .authenticationFailed, Date().timeIntervalSince(lastReconnect) > 5 else { throw failure }
            lastReconnect = Date()
            try await openTask()
        }
        guard let transport else { throw ASRError.notPrepared }
        do {
            try await transport.send(.data(AudioSpec.int16Data(samples)))
        } catch {
            fail(.network(error.localizedDescription))
            throw failure ?? ASRError.network(error.localizedDescription)
        }
        let update = StreamingUpdate(text: currentText, isEndpoint: endpointPending)
        endpointPending = false
        return update
    }

    public func finishUtterance() async -> String {
        let text = currentText
        closedThrough = max(closedThrough, endedSentences.keys.max() ?? 0, openSentence?.id ?? 0)
        endedSentences = [:]
        openSentence = nil
        endpointPending = false
        return text
    }

    public func shutdown() async {
        isShuttingDown = true
        if let transport, isStarted, failure == nil {
            try? await transport.send(.text(FunASRProtocol.finishTask(taskID: taskID)))
            await waitForFinish(timeout: 3)
        }
        closeTransport()
    }

    // MARK: - Connection

    private func openTask() async throws {
        closeTransport()
        failure = nil
        isStarted = false
        isFinished = false
        // `sentence_id` restarts at 1 for every task.
        closedThrough = 0
        endedSentences = [:]
        openSentence = nil
        endpointPending = false
        taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        var request = URLRequest(url: config.webSocketURL)
        request.setValue("bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let socket = connect(request)
        transport = socket
        Task { await self.receiveLoop(socket) }

        do {
            try await socket.send(.text(FunASRProtocol.runTask(taskID: taskID, model: config.model)))
        } catch {
            fail(.network(error.localizedDescription))
        }
        try await waitForStart()
    }

    private func receiveLoop(_ socket: any WebSocketTransport) async {
        do {
            while true {
                let message = try await socket.receive()
                guard socket === transport else { return }
                switch message {
                case .text(let text): handle(FunASRProtocol.parseEvent(Data(text.utf8)))
                case .data(let data): handle(FunASRProtocol.parseEvent(data))
                }
            }
        } catch {
            guard socket === transport else { return }
            if !isShuttingDown {
                fail(.network(error.localizedDescription))
            }
            resumeFinish()
        }
    }

    private func handle(_ event: FunASRProtocol.Event) {
        switch event {
        case .started:
            isStarted = true
            startWaiter?.resume()
            startWaiter = nil
        case .result(let sentence):
            guard sentence.id > closedThrough else { return }
            if sentence.isEnd {
                endedSentences[sentence.id] = sentence.text
                if openSentence?.id == sentence.id { openSentence = nil }
                endpointPending = true
            } else {
                openSentence = (sentence.id, sentence.text)
            }
        case .failed(let code, let message):
            fail(FunASRProtocol.error(code: code, message: message))
            resumeFinish()
        case .finished:
            resumeFinish()
        case .heartbeat, .unknown:
            break
        }
    }

    private func fail(_ error: ASRError) {
        if failure == nil { failure = error }
        startWaiter?.resume(throwing: failure ?? error)
        startWaiter = nil
    }

    private func waitForStart() async throws {
        if isStarted { return }
        if let failure { throw failure }
        let timeout = startTimeout
        let id = taskID
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.startTimedOut(taskID: id)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            startWaiter = cont
        }
    }

    private func startTimedOut(taskID id: String) {
        guard id == taskID, startWaiter != nil else { return }
        fail(.network("连接云端超时"))
    }

    private func waitForFinish(timeout: TimeInterval) async {
        guard !isFinished else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.resumeFinish()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishWaiter = cont
        }
    }

    private func resumeFinish() {
        isFinished = true
        finishWaiter?.resume()
        finishWaiter = nil
    }

    private func closeTransport() {
        transport?.close()
        transport = nil
        startWaiter?.resume(throwing: CancellationError())
        startWaiter = nil
        resumeFinish()
    }

    private var currentText: String {
        endedSentences.keys.sorted().compactMap { endedSentences[$0] }.joined() + (openSentence?.text ?? "")
    }
}
