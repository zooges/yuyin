import Foundation
import YuyinCloud
import YuyinCore
import YuyinLocal

/// Builds a session's engines from settings, local models and the cloud key.
struct AppEngineProvider: EngineProvider {
    let local: LocalEngines
    let apiKey: String

    func makeEngines(for settings: AppSettings) async throws -> EngineSet {
        var local = local
        local.hotwords = settings.hotwords
        local.background = settings.recognitionBackground
        let labeler = settings.speakerLabeling ? local.makeSpeakerLabeler() : nil
        let translator = makeTranslator(settings)
        let voiceDetector = local.makeVoiceDetector()
        switch settings.mode {
        case .offline:
            return EngineSet(
                streaming: try local.makeStreaming(local.resolveStreaming(settings.streamingEngine)),
                corrector: try local.makeCorrector(local.resolveCorrector(settings.corrector)),
                speakerLabeler: labeler,
                translator: translator,
                voiceDetector: voiceDetector
            )
        case .hybrid:
            let fallback = (try? local.resolveCorrector(settings.corrector)).flatMap { try? local.makeCorrector($0) }
            return EngineSet(
                streaming: try local.makeStreaming(local.resolveStreaming(settings.streamingEngine)),
                corrector: try CloudEngines.makeCorrector(apiKey: apiKey),
                fallbackCorrector: fallback,
                speakerLabeler: labeler,
                translator: translator,
                voiceDetector: voiceDetector
            )
        case .cloud:
            return EngineSet(
                streaming: try CloudEngines.makeStreaming(apiKey: apiKey),
                corrector: try CloudEngines.makeCorrector(apiKey: apiKey),
                speakerLabeler: labeler,
                translator: translator,
                voiceDetector: voiceDetector
            )
        }
    }

    /// Translation problems never block recording: they surface as a notice.
    private func makeTranslator(_ settings: AppSettings) -> (any TextTranslator)? {
        let options = settings.translation
        guard options.enabled else { return nil }
        let hasKey = !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        let useCloud: Bool
        switch options.engine {
        case .cloud: useCloud = true
        case .onDevice: useCloud = false
        // "纯离线" never goes online unless the user explicitly picked cloud translation.
        case .auto: useCloud = settings.mode != .offline && hasKey
        }
        if useCloud {
            do {
                return try CloudEngines.makeTranslator(apiKey: apiKey)
            } catch {
                return UnavailableTranslator(error)
            }
        }
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleTranslator(target: options.target)
        }
        return UnavailableTranslator(ASRError.unavailable("系统离线翻译需要 macOS 26 / iOS 26；可改用云端翻译（需百炼 API Key）"))
    }
}

/// What a session would run with the current settings — shown before recording starts.
struct EnginePlan: Equatable {
    var streaming: String
    /// nil = streaming text becomes final as-is.
    var corrector: String?
    var problem: String?

    var summary: String {
        "实时 \(streaming) · " + (corrector.map { "纠错 \($0)" } ?? "不纠错")
    }

    static func make(settings: AppSettings, local: LocalEngines, hasAPIKey: Bool) -> EnginePlan {
        var plan = EnginePlan(streaming: "—", corrector: nil)
        do {
            switch settings.mode {
            case .offline:
                plan.streaming = try local.resolveStreaming(settings.streamingEngine).title
                let corrector = try local.resolveCorrector(settings.corrector)
                plan.corrector = corrector == .none ? nil : corrector.title
            case .hybrid:
                plan.streaming = try local.resolveStreaming(settings.streamingEngine).title
                let fallback = (try? local.resolveCorrector(settings.corrector)).map { $0 == .none ? "无" : $0.title } ?? "无"
                plan.corrector = "Fun-ASR 云端（备用：\(fallback)）"
            case .cloud:
                plan.streaming = "Fun-ASR 实时"
                plan.corrector = "Fun-ASR 云端"
            }
            if settings.mode.requiresCloud && !hasAPIKey {
                throw ASRError.missingAPIKey
            }
        } catch {
            plan.problem = error.localizedDescription
        }
        return plan
    }
}

enum EngineNames {
    static func display(_ providerID: String) -> String {
        switch providerID {
        case "sherpa-zipformer", "sherpa-streaming-zipformer": return "Zipformer"
        case "sherpa-x-asr": return "X-ASR"
        case "sherpa-x-asr-160ms": return "X-ASR 低延迟"
        case "apple-speech", "apple-speech-offline", "apple-speech-corrector": return "系统识别"
        case "funasr-realtime": return "Fun-ASR 实时"
        case "funasr-cloud", "funasr-correct": return "Fun-ASR 云端"
        case "sherpa-sensevoice": return "SenseVoice"
        case "ane-sensevoice", "fluidaudio-sensevoice": return "SenseVoice·ANE"
        case "sherpa-paraformer": return "Paraformer"
        case "sherpa-firered": return "FireRedASR"
        case "sherpa-qwen3-asr": return "Qwen3-ASR"
        case "sherpa-funasr-nano": return "Fun-ASR-Nano"
        case "llama-qwen3-asr-1.7b": return "Qwen3-ASR 1.7B"
        case "qwen-mt": return "千问 MT"
        case "apple-translation": return "系统翻译"
        default: return providerID
        }
    }

    static func summary(_ info: EngineInfo) -> String {
        var parts = ["实时 \(display(info.streaming))"]
        if let corrector = info.corrector {
            parts.append("纠错 \(display(corrector))")
        } else {
            parts.append("不纠错")
        }
        if let fallback = info.fallbackCorrector { parts.append("备用 \(display(fallback))") }
        if info.speakerLabeling { parts.append("多人") }
        if let translator = info.translator { parts.append("翻译 \(display(translator))") }
        return parts.joined(separator: " · ")
    }
}
