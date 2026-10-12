import SwiftUI
import YuyinCore
#if os(macOS)
import AppKit
#endif

enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yuyin", isDirectory: true)
    }

    static var meetings: URL { support.appendingPathComponent("Meetings", isDirectory: true) }
    /// v0.1 stored every meeting in one JSON file.
    static var legacyMeetings: URL { support.appendingPathComponent("meetings.json") }
}

/// Which drop-down card is open below the bar (nil = the live card when recording).
enum PanelMode: Equatable {
    case history
    case settings
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case recognition
    case models
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常用"
        case .recognition: return "识别"
        case .models: return "模型"
        case .cloud: return "云端"
        }
    }
}

@Observable
@MainActor
final class Navigation {
    var panel: PanelMode?
    /// Recording shown inside the history card (nil = the list).
    var historyMeeting: UUID?
    var settingsTab: SettingsTab = .general
    /// Live card shows the whole transcript (bigger) instead of the latest two lines.
    var liveExpanded = false

    func toggle(_ mode: PanelMode) {
        panel = panel == mode ? nil : mode
    }

    func showMeeting(_ id: UUID) {
        historyMeeting = id
        panel = .history
    }

    func showSettings(_ tab: SettingsTab) {
        settingsTab = tab
        panel = .settings
    }
}

/// Shared app state, owned once (the macOS bar panel lives outside SwiftUI scenes).
@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let preferences = Preferences()
    let models = ModelManager()
    let navigation = Navigation()
    let library: MeetingLibrary
    let recorder: Recorder

    private init() {
        library = MeetingLibrary(root: AppPaths.meetings)
        recorder = Recorder(library: library)
    }

    func inject<V: View>(_ view: V) -> some View {
        view
            .environment(preferences)
            .environment(models)
            .environment(library)
            .environment(recorder)
            .environment(navigation)
            .tint(Theme.accent)
    }
}

@main
struct YuyinApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    private let container = AppContainer.shared

    var body: some Scene {
        #if os(macOS)
        // The UI is the floating bar (MacBarPanel); this scene only carries the menu commands.
        Settings { EmptyView() }
            .commands { MacCommands(container: container) }
        #else
        WindowGroup {
            container.inject(PhoneHomeView())
                .task {
                    await container.library.load(legacyFile: AppPaths.legacyMeetings)
                    #if DEBUG
                    if let mode = UserDefaults.standard.string(forKey: "YuyinDemo") {
                        await container.recorder.loadDemo(mode, library: container.library)
                    }
                    if let panel = UserDefaults.standard.string(forKey: "YuyinPanel") {
                        container.navigation.panel = panel == "settings" ? .settings : .history
                    }
                    container.navigation.liveExpanded = UserDefaults.standard.bool(forKey: "YuyinExpanded")
                    #endif
                }
        }
        #endif
    }
}

#if os(iOS)
/// iPhone / iPad: the same bar with drop-down cards, at the top of the screen.
private struct PhoneHomeView: View {
    var body: some View {
        GeometryReader { geo in
            BarHomeView(panelMaxHeight: max(320, geo.size.height - 100), expandedHeight: max(300, geo.size.height - 220))
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.09), Color(red: 0.02, green: 0.02, blue: 0.03)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
