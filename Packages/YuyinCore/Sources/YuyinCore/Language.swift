import Foundation

public enum Language: String, Codable, CaseIterable, Sendable, Identifiable {
    case zh
    case en
    case ja
    case ko

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .zh: return "中文"
        case .en: return "英文"
        case .ja: return "日文"
        case .ko: return "韩文"
        }
    }

    /// Rough script-based guess, good enough to pick a translation direction per sentence.
    public static func guess(_ text: String) -> Language {
        var han = 0, kana = 0, hangul = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if kana > 0 && kana * 4 >= han { return .ja }
        if hangul > 0 && hangul >= han { return .ko }
        // A Latin letter carries much less content than a Han character.
        return han * 3 >= latin ? (han > 0 ? .zh : .en) : .en
    }
}

public enum TranslationTarget: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Chinese → English, everything else → Chinese.
    case auto
    case zh
    case en
    case ja
    case ko

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动（中⇄英）"
        case .zh: return "译成中文"
        case .en: return "译成英文"
        case .ja: return "译成日文"
        case .ko: return "译成韩文"
        }
    }

    /// (source, target) for one sentence, or nil when it is already in the target language.
    public func direction(for text: String) -> (source: Language, target: Language)? {
        let source = Language.guess(text)
        let target: Language
        switch self {
        case .auto: target = source == .zh ? .en : .zh
        case .zh: target = .zh
        case .en: target = .en
        case .ja: target = .ja
        case .ko: target = .ko
        }
        return source == target ? nil : (source, target)
    }
}

public enum TranslationEngineChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Offline mode → on-device; hybrid / cloud → Qwen-MT.
    case auto
    case onDevice
    case cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .onDevice: return "系统翻译（本机离线）"
        case .cloud: return "通义千问 MT（云端）"
        }
    }
}

public struct TranslationOptions: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var target: TranslationTarget
    public var engine: TranslationEngineChoice

    public init(enabled: Bool = false, target: TranslationTarget = .auto, engine: TranslationEngineChoice = .auto) {
        self.enabled = enabled
        self.target = target
        self.engine = engine
    }
}

public enum AudioSourceChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case microphone
    /// Everything the Mac plays (meeting apps, browsers, other apps), excluding Yuyin.
    case systemAudio
    /// Only the selected app's audio.
    case app
    /// Microphone + system audio (you and the other side of a call).
    case meeting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统声音"
        case .app: return "指定应用"
        case .meeting: return "会议（麦克风 + 系统声音）"
        }
    }

    public var detail: String {
        switch self {
        case .microphone: return "录制身边的声音"
        case .systemAudio: return "腾讯会议、网页、视频等电脑播放的所有声音"
        case .app: return "只录选定应用发出的声音"
        case .meeting: return "同时录自己（麦克风）和对方（会议软件），自动消除外放回声"
        }
    }

    public var usesMicrophone: Bool { self == .microphone || self == .meeting }
    public var usesSystemAudio: Bool { self != .microphone }
}
