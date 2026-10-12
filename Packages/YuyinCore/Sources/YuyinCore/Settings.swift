import Foundation

public enum StreamingEngineChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Sherpa Zipformer if installed, otherwise on-device Apple Speech.
    case auto
    case sherpa
    case appleSpeech

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .sherpa: return "Sherpa Zipformer"
        case .appleSpeech: return "系统语音识别（本机）"
        }
    }
}

public enum CorrectorChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Best installed local model.
    case auto
    case funASRNano
    case paraformer
    case senseVoiceANE
    case senseVoice
    case fireRed
    case qwen3ASR
    case appleSpeech
    /// Keep the streaming text as final.
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动（最佳已安装模型）"
        case .senseVoiceANE: return "SenseVoice · 神经网络引擎"
        case .senseVoice: return "SenseVoice · Sherpa"
        case .paraformer: return "Paraformer-large（纯中文）"
        case .fireRed: return "FireRedASR 大模型"
        case .funASRNano: return "Fun-ASR-Nano（推荐，中英混说）"
        case .qwen3ASR: return "Qwen3-ASR 大模型"
        case .appleSpeech: return "系统语音识别（本机）"
        case .none: return "不纠错"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var mode: TranscriptMode
    public var streamingEngine: StreamingEngineChoice
    /// Local second pass (offline mode, and hybrid fallback).
    public var corrector: CorrectorChoice
    /// Trailing silence that closes a sentence.
    public var silenceMs: Int
    /// Hard cap so a sentence never grows past what offline models handle well.
    public var maxUtteranceSeconds: Int
    public var speakerLabeling: Bool
    /// Expected number of speakers; 0 = automatic.
    public var expectedSpeakers: Int
    public var translation: TranslationOptions
    public var audioSource: AudioSourceChoice
    /// Bundle ID for `AudioSourceChoice.app`.
    public var audioAppBundleID: String?
    /// macOS: keep the recording bar above other windows.
    public var floatOnTop: Bool

    public init(
        mode: TranscriptMode = .offline,
        streamingEngine: StreamingEngineChoice = .auto,
        corrector: CorrectorChoice = .auto,
        silenceMs: Int = 700,
        maxUtteranceSeconds: Int = 15,
        speakerLabeling: Bool = true,
        expectedSpeakers: Int = 0,
        translation: TranslationOptions = TranslationOptions(),
        audioSource: AudioSourceChoice = .microphone,
        audioAppBundleID: String? = nil,
        floatOnTop: Bool = true
    ) {
        self.mode = mode
        self.streamingEngine = streamingEngine
        self.corrector = corrector
        self.silenceMs = silenceMs
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.speakerLabeling = speakerLabeling
        self.expectedSpeakers = expectedSpeakers
        self.translation = translation
        self.audioSource = audioSource
        self.audioAppBundleID = audioAppBundleID
        self.floatOnTop = floatOnTop
    }

    private enum CodingKeys: String, CodingKey {
        case mode, streamingEngine, corrector, silenceMs, maxUtteranceSeconds, speakerLabeling, expectedSpeakers
        case translation, audioSource, audioAppBundleID, floatOnTop
        // v0.1 keys
        case preferSherpaWhenAvailable, preferFireRedCorrector, enableSpeakerLabeling, expectedSpeakerCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        mode = (try? c.decodeIfPresent(TranscriptMode.self, forKey: .mode)) ?? defaults.mode
        silenceMs = (try? c.decodeIfPresent(Int.self, forKey: .silenceMs)) ?? defaults.silenceMs
        let storedMax = (try? c.decodeIfPresent(Int.self, forKey: .maxUtteranceSeconds)) ?? defaults.maxUtteranceSeconds
        // 25 s was the old default; 15 s gives continuous audio (videos, calls) timelier finals.
        maxUtteranceSeconds = storedMax == 25 ? defaults.maxUtteranceSeconds : storedMax

        let legacySherpa = try? c.decodeIfPresent(Bool.self, forKey: .preferSherpaWhenAvailable)
        let legacyFireRed = try? c.decodeIfPresent(Bool.self, forKey: .preferFireRedCorrector)
        streamingEngine = (try? c.decodeIfPresent(StreamingEngineChoice.self, forKey: .streamingEngine))
            ?? (legacySherpa == false ? .appleSpeech : defaults.streamingEngine)
        corrector = (try? c.decodeIfPresent(CorrectorChoice.self, forKey: .corrector))
            ?? (legacySherpa == false ? .appleSpeech : legacyFireRed == true ? .fireRed : defaults.corrector)
        speakerLabeling = (try? c.decodeIfPresent(Bool.self, forKey: .speakerLabeling))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .enableSpeakerLabeling))
            ?? defaults.speakerLabeling
        expectedSpeakers = (try? c.decodeIfPresent(Int.self, forKey: .expectedSpeakers))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .expectedSpeakerCount))
            ?? defaults.expectedSpeakers
        translation = (try? c.decodeIfPresent(TranslationOptions.self, forKey: .translation)) ?? defaults.translation
        audioSource = (try? c.decodeIfPresent(AudioSourceChoice.self, forKey: .audioSource)) ?? defaults.audioSource
        audioAppBundleID = try? c.decodeIfPresent(String.self, forKey: .audioAppBundleID)
        floatOnTop = (try? c.decodeIfPresent(Bool.self, forKey: .floatOnTop)) ?? defaults.floatOnTop
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(streamingEngine, forKey: .streamingEngine)
        try c.encode(corrector, forKey: .corrector)
        try c.encode(silenceMs, forKey: .silenceMs)
        try c.encode(maxUtteranceSeconds, forKey: .maxUtteranceSeconds)
        try c.encode(speakerLabeling, forKey: .speakerLabeling)
        try c.encode(expectedSpeakers, forKey: .expectedSpeakers)
        try c.encode(translation, forKey: .translation)
        try c.encode(audioSource, forKey: .audioSource)
        try c.encodeIfPresent(audioAppBundleID, forKey: .audioAppBundleID)
        try c.encode(floatOnTop, forKey: .floatOnTop)
    }
}

/// UserDefaults-backed settings. Secrets never live here (see `SecretStore`).
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "yuyin.settings"
    private let lock = NSLock()
    private var cached: AppSettings

    public init(defaults: UserDefaults = .standard, secrets: SecretStore? = nil) {
        self.defaults = defaults
        let data = defaults.data(forKey: key)
        cached = data.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()

        // v0.1 stored the cloud API key in plain text inside the settings blob.
        if let data,
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           raw["apiKey"] != nil {
            let legacyKey = (raw["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var safeToScrub = legacyKey.isEmpty
            if !legacyKey.isEmpty, let secrets {
                if !(secrets.read(.funASRKey) ?? "").isEmpty {
                    safeToScrub = true
                } else {
                    safeToScrub = (try? secrets.write(legacyKey, for: .funASRKey)) != nil
                }
            }
            // Never drop the only copy of the key.
            if safeToScrub { persist(cached) }
        }
    }

    public var settings: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    public func update(_ transform: (inout AppSettings) -> Void) {
        lock.lock()
        transform(&cached)
        let snapshot = cached
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
