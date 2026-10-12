import Foundation

/// Result of feeding one chunk to a streaming engine. Returned synchronously from
/// `accept` so partial text can never arrive after the sentence it belongs to was closed.
public struct StreamingUpdate: Equatable, Sendable {
    /// Text of the currently open sentence.
    public var text: String
    /// The engine itself detected a sentence end.
    public var isEndpoint: Bool
    /// Seconds into the open sentence where the engine wrote a clause-ending mark ("，" "。"),
    /// for engines that punctuate as they go (X-ASR): where a length cut does least harm.
    /// (Cutting fluent speech at every comma did harm: the corrector loses context.)
    public var clauseEnds: [Double]
    /// Seconds into the open sentence of the latest word in `text`, when the engine knows.
    public var heardUntil: Double?

    public init(text: String, isEndpoint: Bool = false, clauseEnds: [Double] = [], heardUntil: Double? = nil) {
        self.text = text
        self.isEndpoint = isEndpoint
        self.clauseEnds = clauseEnds
        self.heardUntil = heardUntil
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
    /// Like `finishUtterance()` for a cut `seconds` after the sentence began (a cut in the
    /// past): only the text heard before that point. The session feeds the audio after it again.
    func finishUtterance(keepingUntil seconds: Double) async -> String
    func shutdown() async
}

public extension StreamingASREngine {
    /// Engines without token times keep all text; the next sentence repeats a few words.
    func finishUtterance(keepingUntil seconds: Double) async -> String {
        await finishUtterance()
    }
}

/// Second pass: re-decode one sentence with a more accurate model.
public protocol CorrectorASREngine: AnyObject, Sendable {
    var providerID: String { get }
    func prepare() async throws
    /// `hint` is the streaming text; implementations may return it when they hear nothing.
    func correct(_ samples: [Float], hint: String) async throws -> String
    /// Like `correct`, for the first part of a sentence still being spoken (shown early, then
    /// replaced): engines that remember what they transcribed must not remember this.
    func preview(_ samples: [Float], hint: String) async throws -> String
    func shutdown() async
}

public extension CorrectorASREngine {
    func preview(_ samples: [Float], hint: String) async throws -> String {
        try await correct(samples, hint: hint)
    }
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
    /// The clip's voice embedding, for finding speaker changes inside a sentence; nil when
    /// unsupported or the clip is unusable.
    func embed(_ samples: [Float]) async -> [Float]?
    func shutdown() async
}

public extension SpeakerLabeling {
    func embed(_ samples: [Float]) async -> [Float]? { nil }
}

/// One decision of a model-based voice detector: whether the audio up to `endSample`
/// (absolute within the session) is speech.
public struct VoiceDecision: Equatable, Sendable {
    public let endSample: Int
    public let isSpeech: Bool

    public init(endSample: Int, isSpeech: Bool) {
        self.endSample = endSample
        self.isSpeech = isSpeech
    }
}

/// Decides speech by what the audio sounds like rather than how loud it is. In a meeting
/// room the energy VAD's noise floor rose with continuous discussion until distant voices
/// counted as silence, so sentences were cut in mid-speech and merged across speakers.
/// Calls are serialized by the session, in capture order.
public protocol VoiceActivityDetecting: AnyObject, Sendable {
    func prepare() async throws
    /// Decisions for the windows completed by `samples`, in order.
    func detect(_ samples: [Float]) async -> [VoiceDecision]
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
    /// nil = the segmenter's energy VAD decides on its own.
    public var voiceDetector: (any VoiceActivityDetecting)?

    public init(
        streaming: any StreamingASREngine,
        corrector: (any CorrectorASREngine)?,
        fallbackCorrector: (any CorrectorASREngine)? = nil,
        speakerLabeler: (any SpeakerLabeling)? = nil,
        translator: (any TextTranslator)? = nil,
        voiceDetector: (any VoiceActivityDetecting)? = nil
    ) {
        self.streaming = streaming
        self.corrector = corrector
        self.fallbackCorrector = fallbackCorrector
        self.speakerLabeler = speakerLabeler
        self.translator = translator
        self.voiceDetector = voiceDetector
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
