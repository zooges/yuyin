import SwiftUI
import YuyinCore
import YuyinLocal

enum BarLayout {
    static let width: CGFloat = 500
    static let expandedWidth: CGFloat = 760
    /// Room around the surfaces so their shadows fade out before the window edge.
    static let margin: CGFloat = 24
}

private struct PanelMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 540
}

private struct ExpandedHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 640
}

extension EnvironmentValues {
    /// Tallest a drop-down card may get before its content scrolls.
    var panelMaxHeight: CGFloat {
        get { self[PanelMaxHeightKey.self] }
        set { self[PanelMaxHeightKey.self] = newValue }
    }

    /// Transcript height of the expanded live card.
    var expandedTranscriptHeight: CGFloat {
        get { self[ExpandedHeightKey.self] }
        set { self[ExpandedHeightKey.self] = newValue }
    }
}

/// Home: a capsule bar and one card that drops down below it.
struct BarHomeView: View {
    var panelMaxHeight: CGFloat = 540
    var expandedHeight: CGFloat = 640
    @Environment(Recorder.self) private var recorder
    @Environment(Navigation.self) private var navigation

    private enum Card: Equatable {
        case live, history, settings
    }

    private var card: Card? {
        switch navigation.panel {
        case .history: return .history
        case .settings: return .settings
        case nil:
            let live = recorder.isActive || recorder.completedMeetingID != nil
                || recorder.errorMessage != nil || recorder.notice != nil
            return live ? .live : nil
        }
    }

    private var expanded: Bool { card == .live && navigation.liveExpanded && recorder.isActive }

    var body: some View {
        VStack(spacing: 0) {
            // The bar never moves and stays above the card, which unfolds just below it.
            ControlBar()
                .zIndex(1)
            // Only the card animates. Animating the whole panel also animated the moment the
            // window was still catching up with the new size, so the card slid over the bar.
            ZStack(alignment: .top) {
                if let card {
                    Group {
                        switch card {
                        case .live: LiveCard()
                        case .history: HistoryPanel()
                        case .settings: SettingsPanel()
                        }
                    }
                    .padding(Theme.inset)
                    .hudCard()
                    .padding(.top, 10)
                    .id(card)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.1), value: card)
            .animation(.spring(duration: 0.3, bounce: 0.1), value: expanded)
        }
        .environment(\.panelMaxHeight, panelMaxHeight)
        .environment(\.expandedTranscriptHeight, expandedHeight)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        #if os(macOS)
        .frame(width: expanded ? BarLayout.expandedWidth : BarLayout.width)
        .padding(BarLayout.margin)
        #else
        .frame(maxWidth: 640)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        #endif
    }
}

// MARK: - Bar

private struct ControlBar: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var models
    @Environment(Navigation.self) private var navigation

    var body: some View {
        HStack(spacing: 10) {
            RecordButton(isRecording: recorder.isActive, isListening: recorder.phase == .listening) {
                Task {
                    if recorder.isActive {
                        await recorder.stop()
                    } else {
                        navigation.panel = nil
                        await recorder.start(preferences: preferences, models: models)
                    }
                }
            }
            .disabled(recorder.phase == .preparing || recorder.phase == .finishing)
            .help(recorder.isActive ? "结束录音（⌘R）" : "开始录音（⌘R）")

            if recorder.isActive {
                activeStatus
            } else {
                idleStatus
            }

            Spacer(minLength: 8)

            IconButton(systemName: "text.alignleft", help: "录音记录（⌘L）", isActive: navigation.panel == .history) {
                navigation.toggle(.history)
            }
            IconButton(systemName: "gearshape", help: "设置（⌘,）", isActive: navigation.panel == .settings) {
                navigation.toggle(.settings)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: Theme.barHeight)
        .hudCapsule()
    }

    private var idleStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("开始录音")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.textPrimary)
            SourceMenu()
        }
    }

    @ViewBuilder
    private var activeStatus: some View {
        if recorder.phase == .preparing || recorder.phase == .finishing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.secondaryText)
                Text(recorder.phase.title).font(Theme.bodyFont).foregroundStyle(Theme.secondaryText)
            }
        } else {
            HStack(spacing: 12) {
                Text(Format.duration(recorder.elapsedMs))
                    .font(Theme.timerFont)
                    .monospacedDigit()
                    .foregroundStyle(recorder.phase == .paused ? Theme.secondaryText : Theme.textPrimary)
                Waveform(level: recorder.level, active: recorder.phase == .listening)
                IconButton(
                    systemName: recorder.phase == .paused ? "play.fill" : "pause.fill",
                    help: recorder.phase == .paused ? "继续（⇧⌘P）" : "暂停（⇧⌘P）",
                    size: 30
                ) {
                    Task {
                        if recorder.phase == .paused {
                            await recorder.resume(preferences: preferences)
                        } else {
                            await recorder.pause()
                        }
                    }
                }
                if navigation.panel != nil {
                    IconButton(systemName: "captions.bubble", help: "回到实时字幕", size: 30) { navigation.panel = nil }
                }
            }
        }
    }
}

/// "麦克风 · 纯离线 ⌄" under the title: picks the audio source before recording.
private struct SourceMenu: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Menu {
            Picker("音源", selection: $preferences.settings.audioSource) {
                ForEach(availableSources) { source in
                    Label(source.title, systemImage: source.symbol).tag(source)
                }
            }
            .pickerStyle(.inline)
            #if os(macOS)
            if preferences.settings.audioSource == .app {
                Picker("应用", selection: Binding(
                    get: { preferences.settings.audioAppBundleID ?? "" },
                    set: { preferences.settings.audioAppBundleID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(RecordableApps.running()) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
            }
            #endif
        } label: {
            HStack(spacing: 3) {
                Text("\(shortTitle(preferences.settings.audioSource)) · \(preferences.settings.mode.title)")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Theme.metaFont)
            .foregroundStyle(Theme.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择音源")
    }

    private func shortTitle(_ source: AudioSourceChoice) -> String {
        switch source {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统声音"
        case .app: return "指定应用"
        case .meeting: return "会议"
        }
    }

    private var availableSources: [AudioSourceChoice] {
        AudioCapture.supportsSystemAudio ? AudioSourceChoice.allCases : [.microphone]
    }
}

extension AudioSourceChoice {
    var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .systemAudio: return "speaker.wave.2"
        case .app: return "app.badge"
        case .meeting: return "person.2.wave.2"
        }
    }
}

// MARK: - Live card

private struct LiveCard: View {
    @Environment(Recorder.self) private var recorder
    @Environment(MeetingLibrary.self) private var library
    @Environment(Navigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = recorder.errorMessage {
                let needsSettings = error.contains("设置") || error.contains("模型") || error.contains("Key")
                MessageRow(
                    text: error, isError: true,
                    actionTitle: needsSettings ? "打开设置" : nil,
                    action: needsSettings ? {
                        recorder.errorMessage = nil
                        navigation.showSettings(error.contains("Key") ? .cloud : .models)
                    } : nil
                ) { recorder.errorMessage = nil }
            }
            if let notice = recorder.notice {
                MessageRow(text: notice) { recorder.notice = nil }
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if recorder.notice == notice { recorder.notice = nil }
                    }
            }
            if recorder.isActive {
                if navigation.liveExpanded {
                    ExpandedTranscript()
                } else {
                    Captions()
                }
            } else if let id = recorder.completedMeetingID, let meeting = library.meeting(id) {
                CompletionContent(meeting: meeting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "翻译中…" only for recent sentences that actually need translating.
@MainActor
func expectsTranslation(_ u: Utterance, in recorder: Recorder, target: TranslationTarget) -> Bool {
    guard recorder.engineInfo?.translator != nil, u.status == .final, u.translation == nil,
          target.direction(for: u.displayText) != nil
    else { return false }
    return recorder.utterances.suffix(3).contains { $0.id == u.id }
}

@MainActor
private func speakerOptions(_ recorder: Recorder) -> [SpeakerOption] {
    recorder.speakerIndices.map { SpeakerOption(index: $0, label: recorder.label(for: $0) ?? "") }
}

/// Subtitle-style: the previous sentence dimmed, the current one large, its translation below.
private struct Captions: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Navigation.self) private var navigation
    @Environment(Preferences.self) private var preferences

    private var translationOn: Bool { recorder.engineInfo?.translator != nil }
    private var labeling: Bool { recorder.engineInfo?.speakerLabeling == true }

    var body: some View {
        let lines = recorder.latest(2)
        let current = lines.last
        let previous = lines.count == 2 ? lines.first : nil
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                if let previous {
                    VStack(alignment: .leading, spacing: 3) {
                        speaker(previous)
                        Text(previous.displayText)
                            .font(Theme.previousCaptionFont)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                if let current {
                    VStack(alignment: .leading, spacing: 4) {
                        speaker(current)
                        Text(current.displayText.isEmpty ? "…" : current.displayText)
                            .font(Theme.captionFont)
                            .lineSpacing(3)
                            .foregroundStyle(current.status == .final ? Theme.textPrimary : Theme.textPrimary.opacity(0.78))
                            .lineLimit(2)
                            .truncationMode(.head)
                        if let translation = current.translation {
                            Text(translation)
                                .font(Theme.translationFont)
                                .foregroundStyle(Theme.translation)
                                .lineLimit(2)
                                .truncationMode(.head)
                        } else if expectsTranslation(current, in: recorder, target: preferences.settings.translation.target) {
                            Text("翻译中…").font(Theme.metaFont).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, minHeight: translationOn ? 128 : 96, alignment: .topLeading)
            .padding(.trailing, 28)

            IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "展开完整记录", size: 26) {
                navigation.liveExpanded = true
            }
            .padding(.trailing, -6)
            .padding(.top, -6)
        }
    }

    @ViewBuilder
    private func speaker(_ u: Utterance) -> some View {
        if labeling {
            if u.status == .final || u.speakerIndex != nil {
                SpeakerTag(
                    utterance: u, label: recorder.label(for: u.speakerIndex), options: speakerOptions(recorder),
                    onRename: { recorder.renameSpeaker($0, to: $1) },
                    onReassign: { recorder.reassign(u.id, to: $0) }
                )
            } else {
                PendingSpeaker()
            }
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            if recorder.phase == .preparing {
                ProgressView().controlSize(.small).tint(Theme.secondaryText)
            }
            Text(recorder.phase == .preparing ? "正在准备模型…" : "正在聆听，请开始说话")
                .font(Theme.previousCaptionFont)
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// The whole live transcript, following the newest sentence.
private struct ExpandedTranscript: View {
    @Environment(Recorder.self) private var recorder
    @Environment(Navigation.self) private var navigation
    @Environment(Preferences.self) private var preferences
    @Environment(\.expandedTranscriptHeight) private var height

    var body: some View {
        let options = speakerOptions(recorder)
        let labeling = recorder.engineInfo?.speakerLabeling == true
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "实时记录", subtitle: subtitle(speakers: options.count)) {
                IconButton(systemName: "arrow.down.right.and.arrow.up.left", help: "收起", size: 28) {
                    navigation.liveExpanded = false
                }
                .padding(.trailing, -6)
            }
            if labeling && !options.isEmpty {
                SpeakerRoster(options: options) { recorder.renameSpeaker($0, to: $1) }
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if recorder.utterances.isEmpty {
                            Text("正在聆听，请开始说话")
                                .font(Theme.previousCaptionFont)
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                        ForEach(recorder.utterances) { u in
                            TranscriptRow(
                                utterance: u,
                                translationPending: expectsTranslation(u, in: recorder, target: preferences.settings.translation.target)
                            ) {
                                if labeling {
                                    if u.status == .final || u.speakerIndex != nil {
                                        SpeakerTag(
                                            utterance: u, label: recorder.label(for: u.speakerIndex), options: options,
                                            onRename: { recorder.renameSpeaker($0, to: $1) },
                                            onReassign: { recorder.reassign(u.id, to: $0) }
                                        )
                                    } else {
                                        PendingSpeaker()
                                    }
                                }
                            }
                            .id(u.id)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                    .padding(.trailing, 8)
                }
                .onChange(of: recorder.utterances.last?.displayText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
                .onChange(of: recorder.utterances.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("live-bottom", anchor: .bottom) }
            }
            .frame(height: height)
        }
    }

    private func subtitle(speakers: Int) -> String {
        var parts = ["\(recorder.utterances.count) 句"]
        if speakers > 0 { parts.append("\(speakers) 位说话人") }
        return parts.joined(separator: " · ")
    }
}

private struct CompletionContent: View {
    let meeting: Meeting
    @Environment(Recorder.self) private var recorder
    @Environment(Navigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.6))
                VStack(alignment: .leading, spacing: 3) {
                    Text("已保存").font(Theme.titleFont).foregroundStyle(Theme.textPrimary)
                    Text(summary).font(Theme.metaFont).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer()
                IconButton(systemName: "xmark", help: "关闭", size: 26) { recorder.dismissCompletion() }
                    .padding(.trailing, -6)
            }
            HStack(spacing: 8) {
                ExportMenu(meeting: meeting, style: .primary)
                Button("查看记录") {
                    recorder.dismissCompletion()
                    navigation.showMeeting(meeting.id)
                }
                .buttonStyle(.hud(.secondary))
            }
        }
    }

    private var summary: String {
        var parts = [meeting.title, Format.duration(meeting.durationMs), "\(meeting.utterances.count) 句"]
        let speakers = meeting.speakerIndices.count
        if speakers > 1 { parts.append("\(speakers) 位说话人") }
        return parts.joined(separator: " · ")
    }
}
