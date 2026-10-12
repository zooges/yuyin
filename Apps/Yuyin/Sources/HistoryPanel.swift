import SwiftUI
import YuyinCore
import YuyinLocal

/// "录音记录" card: list → detail, all inside the drop-down.
struct HistoryPanel: View {
    @Environment(Navigation.self) private var navigation
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        if let id = navigation.historyMeeting, let meeting = library.meeting(id) {
            MeetingDetailCard(meeting: meeting)
        } else {
            MeetingListCard()
        }
    }
}

private struct MeetingListCard: View {
    @Environment(Navigation.self) private var navigation
    @Environment(MeetingLibrary.self) private var library
    @Environment(Recorder.self) private var recorder
    @Environment(\.panelMaxHeight) private var maxHeight
    @State private var search = ""

    private var filteredMeetings: [Meeting] {
        library.meetings.filter { meeting in
            guard meeting.id != recorder.meetingID else { return false }
            guard !search.isEmpty else { return true }
            // Sentence by sentence: stops at the first hit instead of joining the whole transcript.
            return meeting.title.localizedCaseInsensitiveContains(search)
                || meeting.utterances.contains { $0.displayText.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        let meetings = filteredMeetings
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "录音记录", subtitle: library.meetings.isEmpty ? nil : "共 \(library.meetings.count) 条",
                       close: { navigation.panel = nil })
            HUDSearchField(prompt: "搜索标题或内容", text: $search)
            if meetings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: search.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(search.isEmpty ? "还没有录音记录" : "没有匹配的记录")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                            if index > 0 { RowDivider(inset: 10) }
                            MeetingRow(meeting: meeting, interrupted: library.interrupted.contains(meeting.id)) {
                                navigation.historyMeeting = meeting.id
                            }
                        }
                    }
                }
                .frame(maxHeight: maxHeight - 120)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let interrupted: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.shortDate(meeting.createdAt) + "  ·  " + Format.duration(meeting.durationMs))
                        .font(Theme.metaFont)
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiaryText)
                }
                Text(preview.isEmpty ? "（无内容）" : preview)
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                if interrupted {
                    Text("录音意外中断，已保留识别内容").font(Theme.microFont).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// The opening sentences: the row shows one line, so don't join a whole transcript for it.
    private var preview: String {
        var parts: [String] = []
        var length = 0
        for text in meeting.utterances.lazy.map(\.displayText) where TextFilter.isMeaningful(text) {
            parts.append(text)
            length += text.count
            if length >= 200 { break }
        }
        return parts.joined(separator: " ")
    }
}

private enum TranscriptVersion: String, CaseIterable, Identifiable {
    case polished
    case original

    var id: String { rawValue }
    var title: String { self == .polished ? "润色稿" : "原文" }
}

private struct MeetingDetailCard: View {
    let meeting: Meeting
    @Environment(Navigation.self) private var navigation
    @Environment(MeetingLibrary.self) private var library
    @Environment(ModelManager.self) private var models
    @Environment(Preferences.self) private var preferences
    @Environment(\.panelMaxHeight) private var maxHeight

    @State private var search = ""
    @State private var speakerFilter: Int?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @State private var analyzing = false
    @State private var message: String?
    /// Show the 润色 text where there is one.
    @State private var version = TranscriptVersion.polished

    private var hasPolished: Bool { meeting.utterances.contains { $0.polished != nil } }

    private var book: SpeakerBook { meeting.speakerBook }

    private func speakerOptions(_ book: SpeakerBook) -> [SpeakerOption] {
        meeting.speakerIndices.map { SpeakerOption(index: $0, label: book.label(for: $0) ?? "") }
    }

    private var filteredLines: [Utterance] {
        meeting.utterances
            .filter { u in
                if let speakerFilter, u.speakerIndex != speakerFilter { return false }
                return search.isEmpty
                    || u.displayText.localizedCaseInsensitiveContains(search)
                    || (u.translation?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .sorted { $0.startMs < $1.startMs }
            // In the 润色 text, a sentence merged into the one before ("") is not shown.
            .filter { version == .original || $0.polished != "" }
            .map { u in
                guard version == .polished, let polished = u.polished else { return u }
                var shown = u
                shown.finalText = polished
                shown.status = .final
                return shown
            }
    }

    var body: some View {
        // Computed once per render; every row used to recompute them.
        let book = self.book
        let options = speakerOptions(book)
        let lines = filteredLines
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: meeting.title, subtitle: meta, back: { navigation.historyMeeting = nil }, close: { navigation.panel = nil }) {
                ExportMenu(meeting: meeting, subset: lines, style: .secondary)
                Menu {
                    Button("重命名") {
                        newTitle = meeting.title
                        renaming = true
                    }
                    if LocalEngines.supportsLlama {
                        Button(models.installed.contains(.polishModel)
                               ? (hasPolished ? "重新润色" : "润色（整理成书面记录）") : "润色（需下载润色模型）") {
                            startPolish()
                        }
                        .disabled(library.polishing != nil)
                    }
                    Button(models.engines.canLabelSpeakers ? "重新分析说话人" : "重新分析说话人（需下载说话人声纹模型）") {
                        Task { await analyze() }
                    }
                    .disabled(analyzing || !library.hasAudio(meeting.id))
                    Divider()
                    Button("删除…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if renaming {
                HStack(spacing: 8) {
                    TextField("标题", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(Theme.bodyFont)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.fill))
                        .onSubmit(saveTitle)
                    Button("取消") { renaming = false }.buttonStyle(.hud(.quiet))
                    Button("保存", action: saveTitle).buttonStyle(.hud(.primary))
                }
            }
            if confirmingDelete {
                InlineConfirm(prompt: "删除这条记录和录音？", confirmTitle: "删除") {
                    navigation.historyMeeting = nil
                    Task { await library.delete(meeting.id) }
                } onCancel: {
                    confirmingDelete = false
                }
            }
            if let message {
                MessageRow(text: message) { self.message = nil }
            }
            if let polishing = library.polishing, polishing.id == meeting.id {
                HStack(spacing: 8) {
                    ProgressView(value: polishing.progress).controlSize(.small).tint(Theme.secondaryText).frame(width: 80)
                    Text("正在润色… \(Int(polishing.progress * 100))%").font(Theme.metaFont).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("取消") { library.cancelPolish() }.buttonStyle(.hud(.quiet))
                }
            }
            if hasPolished {
                TabSwitcher(tabs: TranscriptVersion.allCases, selection: $version) { $0.title }
            }
            if analyzing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.secondaryText)
                    Text("正在分析说话人…").font(Theme.metaFont).foregroundStyle(Theme.secondaryText)
                }
            }

            HStack(spacing: 10) {
                HUDSearchField(prompt: "在本记录中搜索", text: $search)
                if options.count > 1 {
                    Menu {
                        Picker("说话人", selection: $speakerFilter) {
                            Text("全部说话人").tag(Int?.none)
                            ForEach(options) { Text($0.label).tag(Int?.some($0.index)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 4) {
                            Text(speakerFilter.flatMap { book.label(for: $0) } ?? "全部")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(Theme.metaFont)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.fill))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if options.count > 0 {
                SpeakerRoster(options: options) { index, name in
                    Task { await library.renameSpeaker(index, to: name, in: meeting.id) }
                }
            }

            Rectangle().fill(Theme.separator).frame(height: 1)
            if lines.isEmpty {
                Text("没有匹配的内容")
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { utterance in
                            TranscriptRow(utterance: utterance) {
                                if utterance.speakerIndex != nil || !options.isEmpty {
                                    SpeakerTag(
                                        utterance: utterance,
                                        label: book.label(for: utterance.speakerIndex),
                                        options: options,
                                        onRename: { index, name in
                                            Task { await library.renameSpeaker(index, to: name, in: meeting.id) }
                                        },
                                        onReassign: { target in
                                            Task { await library.reassign(utterance.id, to: target, in: meeting.id) }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: maxHeight - 200)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var meta: String {
        var parts = [Format.date(meeting.createdAt), Format.duration(meeting.durationMs), "\(meeting.utterances.count) 句"]
        if library.interrupted.contains(meeting.id) { parts.append("曾意外中断") }
        return parts.joined(separator: " · ")
    }

    private func startPolish() {
        guard models.installed.contains(.polishModel) else {
            message = "请先在 设置 → 模型 中下载「润色模型」（约 2.5 GB，本机运行，内容不上传）"
            return
        }
        version = .polished
        library.polish(meeting.id, engines: models.engines, settings: preferences.settings)
    }

    private func saveTitle() {
        renaming = false
        Task { await library.rename(meeting.id, to: newTitle) }
    }

    private func analyze() async {
        guard models.engines.canLabelSpeakers else {
            message = "请先在 设置 → 模型 中下载「说话人声纹」"
            return
        }
        analyzing = true
        defer { analyzing = false }
        do {
            let count = try await library.analyzeSpeakers(
                meeting.id, engines: models.engines, expectedSpeakers: preferences.settings.expectedSpeakers
            )
            speakerFilter = nil
            message = count > 0 ? "已识别出 \(count) 位说话人（已起的名字会保留）" : "没有区分出说话人"
        } catch {
            message = error.localizedDescription
        }
    }
}
