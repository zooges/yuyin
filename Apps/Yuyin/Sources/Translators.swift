import Foundation
import SwiftUI
import YuyinCore
#if canImport(Translation)
import Translation
#endif

/// On-device translation with Apple's Translation framework. Languages must be
/// downloaded once (Settings → 翻译 → 下载离线翻译语言).
@available(macOS 26.0, iOS 26.0, *)
actor AppleTranslator: TextTranslator {
    nonisolated let providerID = "apple-translation"
    private let target: TranslationTarget
    private var sessions: [String: TranslationSession] = [:]

    init(target: TranslationTarget) {
        self.target = target
    }

    func prepare() async throws {
        // Check the most likely direction up front so a missing download is reported at start.
        let pair: (Language, Language) = target == .auto || target == .en ? (.zh, .en) : (.en, Language(rawValue: target.rawValue) ?? .zh)
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: pair.0.rawValue),
            to: Locale.Language(identifier: pair.1.rawValue)
        )
        switch status {
        case .installed: return
        case .supported: throw ASRError.unavailable("离线翻译语言尚未下载：请在 设置 → 实时翻译 中点「下载离线翻译语言」")
        case .unsupported: throw ASRError.unavailable("系统翻译不支持该语言组合")
        @unknown default: return
        }
    }

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let key = "\(source.rawValue)-\(target.rawValue)"
        let session: TranslationSession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = TranslationSession(
                installedSource: Locale.Language(identifier: source.rawValue),
                target: Locale.Language(identifier: target.rawValue)
            )
            sessions[key] = session
        }
        do {
            return try await session.translate(text).targetText
        } catch {
            throw ASRError.inferenceFailed("系统翻译：\(error.localizedDescription)")
        }
    }

    func shutdown() async {
        sessions.removeAll()
    }
}

/// Stand-in whose `prepare()` fails, so a translation problem becomes a notice
/// instead of blocking the recording.
final class UnavailableTranslator: TextTranslator, @unchecked Sendable {
    let providerID = "translation-unavailable"
    private let error: Error

    init(_ error: Error) {
        self.error = error
    }

    func prepare() async throws { throw error }
    func translate(_ text: String, from source: Language, to target: Language) async throws -> String { throw error }
    func shutdown() async {}
}

enum OnDeviceTranslation {
    static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { return true }
        return false
    }
}

/// Button that triggers the system's language download sheet for on-device translation.
struct PrepareTranslationButton: View {
    let target: TranslationTarget
    @State private var trigger = false
    @State private var status: String?

    var body: some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            HStack {
                Button("下载") { trigger.toggle() }.buttonStyle(.hud(.secondary))
                if let status {
                    Text(status).font(Theme.metaFont).foregroundStyle(Theme.secondaryText)
                }
            }
            .modifier(PrepareModifier(target: target, trigger: trigger) { status = $0 })
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
private struct PrepareModifier: ViewModifier {
    let target: TranslationTarget
    let trigger: Bool
    let report: (String) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, _ in
                let destination = target == .auto ? "en" : target.rawValue
                let source = destination == "zh" ? "en" : "zh"
                if configuration == nil {
                    configuration = .init(source: Locale.Language(identifier: source), target: Locale.Language(identifier: destination))
                } else {
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    report("已就绪")
                } catch {
                    report(error.localizedDescription)
                }
            }
    }
}
