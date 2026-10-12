#if os(macOS)
import AppKit
import SwiftUI
import YuyinCore

/// Borderless floating panel that hosts the bar and its drop-down cards.
/// Unlike a SwiftUI window it can take keyboard focus (search, API key, renaming)
/// without a title bar, and clicking it doesn't pull focus from the meeting app.
final class MacBarPanel: NSPanel {
    private var hosting: NSHostingView<AnyView>!

    init(container: AppContainer) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BarLayout.width + BarLayout.margin * 2, height: 70),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        title = "余音"

        // Position before the content first reports its size, so cards grow down from the saved spot.
        let anchor = Self.savedAnchor() ?? Self.defaultAnchor()
        setFrameOrigin(NSPoint(x: (anchor.x - frame.width / 2).rounded(), y: anchor.y - frame.height))

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let root = container.inject(
            BarHomeView(panelMaxHeight: 540, expandedHeight: max(360, screenHeight * 0.72 - 160))
                .fixedSize()
                .background(SizeReader { [weak self] size in self?.fit(size) })
                // Pinned to the top: while the window catches up with a new size the bar must not move.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        contentView = hosting

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAnchor() }
        }
    }

    #if DEBUG
    /// UI checks without screen-recording permission: draws the panel's own views.
    func snapshot(to url: URL) {
        guard let view = contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func apply(floatOnTop: Bool) {
        level = floatOnTop ? .floating : .normal
        collectionBehavior = floatOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
    }

    /// The bar stays put (top edge and horizontal centre); the cards grow downward.
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let top = frame.maxY
        let next = NSRect(x: (frame.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height)
        if next != frame {
            setFrame(next, display: true, animate: false)
            hosting.frame = NSRect(origin: .zero, size: size)
        }
    }

    // The bar's anchor is its top edge and horizontal centre; the window's size changes with the cards.
    private static let anchorKey = "YuyinBarAnchor"

    private func saveAnchor() {
        UserDefaults.standard.set([Double(frame.midX), Double(frame.maxY)], forKey: Self.anchorKey)
    }

    private static func savedAnchor() -> NSPoint? {
        guard let values = UserDefaults.standard.array(forKey: anchorKey) as? [Double], values.count == 2 else { return nil }
        let point = NSPoint(x: values[0], y: values[1])
        // Ignore it if that display is gone.
        let onScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: point.x, y: point.y - 1)) }
        return onScreen ? point : nil
    }

    private static func defaultAnchor() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.midX, y: screen.maxY - 4)
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct SizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: SizeKey.self, value: geo.size)
        }
        .onPreferenceChange(SizeKey.self) { size in onChange(size) }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: MacBarPanel?
    private var observation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let container = AppContainer.shared
        let panel = MacBarPanel(container: container)
        self.panel = panel
        panel.apply(floatOnTop: container.preferences.settings.floatOnTop)
        panel.orderFrontRegardless()
        observeFloatSetting(container)
        Task { await container.library.load(legacyFile: AppPaths.legacyMeetings) }
        #if DEBUG
        // UI checks: -YuyinPanel history|settings opens a card at launch.
        if let panel = UserDefaults.standard.string(forKey: "YuyinPanel") {
            container.navigation.panel = panel == "settings" ? .settings : .history
        }
        if let tab = UserDefaults.standard.string(forKey: "YuyinSettingsTab").flatMap(SettingsTab.init(rawValue:)) {
            container.navigation.settingsTab = tab
        }
        container.navigation.liveExpanded = UserDefaults.standard.bool(forKey: "YuyinExpanded")
        if let mode = UserDefaults.standard.string(forKey: "YuyinDemo") {
            Task { await container.recorder.loadDemo(mode, library: container.library) }
        }
        if let path = UserDefaults.standard.string(forKey: "YuyinSnapshot") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                panel.snapshot(to: URL(fileURLWithPath: path))
            }
        }
        // -YuyinReplayWAV <wav>: records the file as if spoken (see AudioCapture), then stops and
        // deletes the recording; -YuyinSnapshotEvery <prefix> captures the panel every 5 s meanwhile.
        if let path = UserDefaults.standard.string(forKey: "YuyinReplayWAV"),
           let samples = try? WAVFile.read(URL(fileURLWithPath: path)) {
            let seconds = Double(samples.count) / Double(AudioSpec.sampleRate)
            let prefix = UserDefaults.standard.string(forKey: "YuyinSnapshotEvery")
            Task {
                await container.recorder.start(preferences: container.preferences, models: container.models)
                var waited = 0.0
                while waited < seconds + 2 {
                    try? await Task.sleep(for: .seconds(5))
                    waited += 5
                    if let prefix { panel.snapshot(to: URL(fileURLWithPath: "\(prefix)-\(Int(waited)).png")) }
                }
                if let id = await container.recorder.stop() { await container.library.delete(id) }
                NSApp.terminate(nil)
            }
        }
        // -YuyinOpenAnimation <prefix>: opens 录音记录 and captures frames of the drop-down.
        if let prefix = UserDefaults.standard.string(forKey: "YuyinOpenAnimation") {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                container.navigation.panel = .history
                for (i, ms) in [40, 90, 150, 400].enumerated() {
                    try? await Task.sleep(for: .milliseconds(i == 0 ? ms : ms - [40, 90, 150, 400][i - 1]))
                    panel.snapshot(to: URL(fileURLWithPath: "\(prefix)-\(ms).png"))
                }
            }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBar()
        return true
    }

    func showBar() {
        panel?.orderFrontRegardless()
    }

    private func observeFloatSetting(_ container: AppContainer) {
        withObservationTracking {
            _ = container.preferences.settings.floatOnTop
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.panel?.apply(floatOnTop: container.preferences.settings.floatOnTop)
                self?.observeFloatSetting(container)
            }
        }
    }
}

/// Menu bar commands (work whenever the app is active).
struct MacCommands: Commands {
    let container: AppContainer

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                container.navigation.toggle(.settings)
                (NSApp.delegate as? MacAppDelegate)?.showBar()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("开始 / 结束录音") {
                Task {
                    if container.recorder.isActive {
                        await container.recorder.stop()
                    } else {
                        await container.recorder.start(preferences: container.preferences, models: container.models)
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("暂停 / 继续") {
                Task {
                    if container.recorder.phase == .paused {
                        await container.recorder.resume(preferences: container.preferences)
                    } else {
                        await container.recorder.pause()
                    }
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()
            Button("录音记录") {
                container.navigation.toggle(.history)
                (NSApp.delegate as? MacAppDelegate)?.showBar()
            }
            .keyboardShortcut("l", modifiers: .command)
            Button("显示录音条") { (NSApp.delegate as? MacAppDelegate)?.showBar() }
        }
    }
}
#endif
