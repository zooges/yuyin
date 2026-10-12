import AVFoundation
import Foundation
import Speech
import YuyinCore

/// Apple Speech, always with `requiresOnDeviceRecognition` — local modes must never
/// send audio to Apple's servers.
enum AppleSpeech {
    static let locale = Locale(identifier: "zh-CN")

    static var isOnDeviceSupported: Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    static func authorizedRecognizer() async throws -> SFSpeechRecognizer {
        let status: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            status = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        } else {
            status = SFSpeechRecognizer.authorizationStatus()
        }
        guard status == .authorized else { throw ASRError.permissionDenied("语音识别") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw ASRError.unavailable("系统中文语音识别当前不可用")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ASRError.unavailable("此设备不支持中文离线语音识别，请在设置中下载 Sherpa 模型")
        }
        return recognizer
    }

    static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(AudioSpec.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

public final class AppleSpeechStreamingEngine: StreamingASREngine, @unchecked Sendable {
    public let providerID = "apple-speech"

    // Recognition callbacks arrive on an Apple queue; all state is guarded by `lock`.
    private let lock = NSRecursiveLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Callbacks from a previous request carry an older generation and are ignored,
    /// so text from a closed sentence can never leak into the next one.
    private var generation = 0
    private var latest = ""
    /// Text from requests that ended on their own (e.g. the ~1 min limit) within this sentence.
    private var carried = ""
    private var needsRestart = false

    public init() {}

    public func prepare() async throws {
        let recognizer = try await AppleSpeech.authorizedRecognizer()
        lock.withLock {
            self.recognizer = recognizer
            beginRequest()
        }
    }

    public func accept(_ samples: [Float]) async throws -> StreamingUpdate {
        guard let buffer = AppleSpeech.makeBuffer(samples) else { return StreamingUpdate(text: currentText()) }
        return lock.withLock {
            if needsRestart {
                carried += latest
                latest = ""
                beginRequest()
            }
            request?.append(buffer)
            return StreamingUpdate(text: carried + latest)
        }
    }

    public func finishUtterance() async -> String {
        lock.withLock {
            let text = carried + latest
            carried = ""
            latest = ""
            beginRequest()
            return text
        }
    }

    public func shutdown() async {
        lock.withLock {
            generation += 1
            request?.endAudio()
            task?.cancel()
            task = nil
            request = nil
            recognizer = nil
        }
    }

    private func currentText() -> String {
        lock.withLock { carried + latest }
    }

    /// Must hold `lock`.
    private func beginRequest() {
        request?.endAudio()
        task?.cancel()
        needsRestart = false
        guard let recognizer else { return }
        generation += 1
        let current = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(generation: current, result: result, error: error)
        }
    }

    private func handle(generation current: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        lock.withLock {
            guard current == generation else { return }
            if let result {
                latest = result.bestTranscription.formattedString
            }
            if error != nil || result?.isFinal == true {
                needsRestart = true
            }
        }
    }
}

public final class AppleSpeechCorrector: CorrectorASREngine, @unchecked Sendable {
    public let providerID = "apple-speech-offline"
    private var recognizer: SFSpeechRecognizer?

    public init() {}

    public func prepare() async throws {
        recognizer = try await AppleSpeech.authorizedRecognizer()
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        guard let recognizer else { throw ASRError.notPrepared }
        guard !samples.isEmpty, let buffer = AppleSpeech.makeBuffer(samples) else { return hint }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    once.run { cont.resume(returning: text.isEmpty ? hint : text) }
                } else if let error {
                    let nsError = error as NSError
                    // 1110 = "No speech detected": not a failure, just nothing to add.
                    if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 {
                        once.run { cont.resume(returning: hint) }
                    } else {
                        once.run { cont.resume(throwing: ASRError.inferenceFailed(error.localizedDescription)) }
                    }
                }
            }
        }
    }

    public func shutdown() async {
        recognizer = nil
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
