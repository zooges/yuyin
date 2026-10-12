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

    /// The directions sentences take for this target (source, target).
    static func directions(for target: TranslationTarget) -> [(String, String)] {
        switch target {
        case .auto: return [("zh", "en"), ("en", "zh")]
        case .zh: return [("en", "zh")]
        case .en: return [("zh", "en")]
        case .ja, .ko: return [("zh", target.rawValue), ("en", target.rawValue)]
        }
    }

    enum Readiness: Equatable {
        case installed
        /// This direction still has to be downloaded.
        case needsDownload(source: String, target: String)
        case unsupported
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func readiness(for target: TranslationTarget) async -> Readiness {
        let availability = LanguageAvailability()
        for (source, destination) in directions(for: target) {
            switch await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: destination)) {
            case .installed: continue
            case .supported: return .needsDownload(source: source, target: destination)
            case .unsupported: return .unsupported
            @unknown default: return .unsupported
            }
        }
        return .installed
    }
}

/// Whether the on-device languages for the target are downloaded, with the system's download
/// sheet for the missing ones.
struct TranslationLanguagesRow: View {
    let target: TranslationTarget
    @State private var readiness: OnDeviceTranslation.Readiness?
    @State private var trigger = false
    @State private var error: String?

    var body: some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            SettingsRow(title: "离线翻译语言", detail: detail) {
                if readiness == .installed {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.6))
                        .padding(.trailing, 6)
                } else if case .needsDownload = readiness {
                    Button("下载") { trigger.toggle() }.buttonStyle(.hud(.secondary))
                }
            }
            .modifier(PrepareModifier(readiness: readiness, trigger: trigger) { failure in
                error = failure
                Task { readiness = await OnDeviceTranslation.readiness(for: target) }
            })
            .task(id: target) {
                error = nil
                readiness = await OnDeviceTranslation.readiness(for: target)
            }
        }
    }

    private var detail: String {
        if let error { return error }
        switch readiness {
        case .installed: return "已下载，可离线翻译"
        case .needsDownload: return "首次使用需下载"
        case .unsupported: return "系统翻译不支持该语言"
        case nil: return "正在检查…"
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
private struct PrepareModifier: ViewModifier {
    let readiness: OnDeviceTranslation.Readiness?
    let trigger: Bool
    /// After the sheet: nil when it went through, else the error.
    let done: (String?) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, _ in
                guard case .needsDownload(let source, let target) = readiness else { return }
                let wanted = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                              target: Locale.Language(identifier: target))
                if configuration?.source == wanted.source && configuration?.target == wanted.target {
                    configuration?.invalidate()
                } else {
                    configuration = wanted
                }
            }
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    done(nil)
                } catch {
                    done(error.localizedDescription)
                }
            }
    }
}
