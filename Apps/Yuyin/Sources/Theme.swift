import SwiftUI
import YuyinCore

/// Design tokens. The floating UI is a dark HUD (like macOS Live Captions): it reads well
/// over any content, so colors are fixed rather than following the system appearance.
enum Theme {
    // MARK: Color
    /// Brand / record color: a warm coral.
    static let record = Color(red: 1.00, green: 0.37, blue: 0.33)
    static let accent = record
    /// Translations: a calm sky blue that separates clearly from the original text.
    static let translation = Color(red: 0.56, green: 0.77, blue: 1.00)

    static let textPrimary = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.60)
    static let tertiaryText = Color.white.opacity(0.38)

    static let fill = Color.white.opacity(0.06)
    static let fillHover = Color.white.opacity(0.10)
    static let fillActive = Color.white.opacity(0.16)
    static let stroke = Color.white.opacity(0.09)
    /// Hairline around the bar and cards: a light edge rather than a dark outline.
    static let edge = Color.white.opacity(0.13)
    static let separator = Color.white.opacity(0.07)

    /// Soft pastels that stay legible on the dark surface.
    static let speakerPalette: [Color] = [
        Color(red: 0.56, green: 0.77, blue: 1.00),
        Color(red: 1.00, green: 0.71, blue: 0.54),
        Color(red: 0.56, green: 0.86, blue: 0.69),
        Color(red: 0.77, green: 0.66, blue: 1.00),
        Color(red: 1.00, green: 0.62, blue: 0.78),
        Color(red: 0.50, green: 0.86, blue: 0.86),
        Color(red: 0.91, green: 0.82, blue: 0.54),
    ]

    static func speakerColor(_ index: Int?) -> Color {
        guard let index, index >= 0 else { return Color.white.opacity(0.35) }
        return speakerPalette[index % speakerPalette.count]
    }

    // MARK: Type
    #if os(iOS)
    static let captionFont = Font.system(size: 20, weight: .medium)
    #else
    static let captionFont = Font.system(size: 19, weight: .medium)
    #endif
    static let previousCaptionFont = Font.system(size: 15)
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 14)
    static let transcriptFont = Font.system(size: 15)
    static let translationFont = Font.system(size: 13.5)
    static let metaFont = Font.system(size: 12)
    static let microFont = Font.system(size: 11, weight: .medium)
    static let monoCaption = Font.system(size: 11, design: .monospaced)
    static let timerFont = Font.system(size: 15, weight: .medium, design: .monospaced)

    // MARK: Shape
    static let barHeight: CGFloat = 56
    static let cardRadius: CGFloat = 22
    static let groupRadius: CGFloat = 12
    static let inset: CGFloat = 16
}

extension SessionPhase {
    var title: String {
        switch self {
        case .idle: return "未在录音"
        case .preparing: return "正在准备…"
        case .listening: return "正在聆听"
        case .paused: return "已暂停"
        case .finishing: return "正在完成…"
        }
    }
}

extension UtteranceStatus {
    var label: String {
        switch self {
        case .partial: return "实时"
        case .pendingCorrection: return "纠错中"
        case .final: return "定稿"
        case .failed: return "未纠错"
        }
    }
}

extension TranscriptMode {
    var symbol: String {
        switch self {
        case .offline: return "lock.shield"
        case .hybrid: return "arrow.triangle.2.circlepath"
        case .cloud: return "cloud"
        }
    }
}

enum Format {
    static func duration(_ ms: Int) -> String {
        TranscriptExporter.clockLabel(ms)
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    static func shortDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天 " + date.formatted(.dateTime.hour().minute())
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天 " + date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
