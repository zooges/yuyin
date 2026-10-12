import Foundation

/// Result of feeding one chunk to a streaming engine. Returned synchronously from
/// `accept` so partial text can never arrive after the sentence it belongs to was closed.
public struct StreamingUpdate: Equatable, Sendable {
    /// Text of the currently open sentence.
    public var text: String
    /// The engine itself detected a sentence end.
    public var isEndpoint: Bool

    public init(text: String, isEndpoint: Bool = false) {
        self.text = text
        self.isEndpoint = isEndpoint
    }
}

/// First pass: low-latency partial text. All audio is 16 kHz mono (`AudioSpec`).
/// Calls are serialized by the session; implementations need not be reentrant.
public protocol StreamingASREngine: AnyObject, Sendable {
    var providerID: String { get }
    func prepare() async throws
    func accept(_ samples: [Float]) async throws -> StreamingUpdate
    /// Closes the open sentence, returns its text and starts a fresh one.
    func finishUtterance() async -> String
    func shutdown() async
}

/// Second pass: re-decode one sentence with a more accurate model.
public protocol CorrectorASREngine: AnyObject, Sendable {
    var providerID: String { get }
    func prepare() async throws
    /// `hint` is the streaming text; implementations may return it when they hear nothing.
    func correct(_ samples: [Float], hint: String) async throws -> String
    func shutdown() async
}

/// Translates finished sentences.
public protocol TextTranslator: AnyObject, Sendable {
    var providerID: String { get }
    func prepare() async throws
    func translate(_ text: String, from source: Language, to target: Language) async throws -> String
    func shutdown() async
}

/// Assigns a speaker cluster to each finalized sentence.
public protocol SpeakerLabeling: AnyObject, Sendable {
    func prepare(expectedSpeakers: Int) async throws
    /// nil when the clip is too short or unusable. `speechMs` = voiced duration of the clip.
    func assign(_ samples: [Float], speechMs: Int) async throws -> Int?
    func shutdown() async
}

/// Whole-recording diarization, run after the session.
public protocol SessionDiarizer: AnyObject, Sendable {
    func prepare(expectedSpeakers: Int) async throws
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment]
    func shutdown() async
}

public struct SpeakerSegment: Equatable, Sendable {
    public let startMs: Int
    public let endMs: Int
    public let speakerIndex: Int

    public init(startMs: Int, endMs: Int, speakerIndex: Int) {
        self.startMs = startMs
        self.endMs = endMs
        self.speakerIndex = speakerIndex
    }
}

public struct EngineSet: Sendable {
    public var streaming: any StreamingASREngine
    public var corrector: (any CorrectorASREngine)?
    /// Hybrid mode: local corrector used when the cloud one fails.
    public var fallbackCorrector: (any CorrectorASREngine)?
    public var speakerLabeler: (any SpeakerLabeling)?
    public var translator: (any TextTranslator)?

    public init(
        streaming: any StreamingASREngine,
        corrector: (any CorrectorASREngine)?,
        fallbackCorrector: (any CorrectorASREngine)? = nil,
        speakerLabeler: (any SpeakerLabeling)? = nil,
        translator: (any TextTranslator)? = nil
    ) {
        self.streaming = streaming
        self.corrector = corrector
        self.fallbackCorrector = fallbackCorrector
        self.speakerLabeler = speakerLabeler
        self.translator = translator
    }
}

/// Builds the engines for a session. Implemented by the app, which knows both
/// local models and cloud credentials.
public protocol EngineProvider: Sendable {
    func makeEngines(for settings: AppSettings) async throws -> EngineSet
}

public enum ASRError: Error, LocalizedError, Equatable, Sendable {
    case notPrepared
    case modelMissing(String)
    case permissionDenied(String)
    case unavailable(String)
    case missingAPIKey
    case authenticationFailed
    case network(String)
    case server(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared: return "引擎尚未准备好"
        case .modelMissing(let name): return "缺少模型：\(name)。请在设置 → 模型中下载。"
        case .permissionDenied(let what): return "未获得\(what)权限，请在系统设置中开启。"
        case .unavailable(let msg): return msg
        case .missingAPIKey: return "当前模式需要云端 API Key，请在设置 → 云端中填写。"
        case .authenticationFailed: return "云端鉴权失败，请检查 API Key。"
        case .network(let msg): return "网络错误：\(msg)"
        case .server(let msg): return "云端返回错误：\(msg)"
        case .inferenceFailed(let msg): return "识别失败：\(msg)"
        }
    }
}
