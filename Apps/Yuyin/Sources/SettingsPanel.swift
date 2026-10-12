import SwiftUI
import UniformTypeIdentifiers
import YuyinCore
import YuyinLocal
#if os(macOS)
import AppKit
#endif

/// "设置" card.
struct SettingsPanel: View {
    @Environment(Navigation.self) private var navigation
    @Environment(ModelManager.self) private var models
    @Environment(\.panelMaxHeight) private var maxHeight

    var body: some View {
        @Bindable var navigation = navigation
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "设置", close: { navigation.panel = nil })
            TabSwitcher(tabs: SettingsTab.allCases, selection: $navigation.settingsTab) { $0.title }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch navigation.settingsTab {
                    case .general: GeneralSettings()
                    case .recognition: RecognitionSettings()
                    case .models: ModelSettings()
                    case .cloud: CloudSettings()
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: maxHeight - 110)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { models.refresh() }
    }
}

/// Drawn rather than a system switch: macOS greys out "on" switches in a panel that isn't key.
private struct HUDToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.22, bounce: 0.15)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? Theme.record : Theme.fillActive)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// Value text with a − / + capsule, the same on both platforms.
private struct HUDStepper: View {
    let text: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(Theme.bodyFont).monospacedDigit().foregroundStyle(Theme.secondaryText)
            HStack(spacing: 0) {
                button("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 14)
                button("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
            }
            .background(Capsule().fill(Theme.fill))
        }
        .fixedSize()
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.textPrimary : Theme.tertiaryText)
        .disabled(!enabled)
    }
}

/// A compact menu picker that reads as plain text with a chevron.
private struct MenuPicker<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(items, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(title(selection))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - 常用

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var models

    var body: some View {
        @Bindable var preferences = preferences
        SettingsGroup(title: "模式", footer: preferences.settings.mode.detail) {
            TabSwitcher(tabs: TranscriptMode.allCases, selection: $preferences.settings.mode) { $0.title }
                .padding(8)
            if preferences.settings.mode.requiresCloud && !preferences.hasAPIKey {
                RowDivider()
                SettingsRow(title: "需要百炼 API Key", detail: "在「云端」中填写") { EmptyView() }
            }
        }

        SettingsGroup(title: "音源") {
            SettingsRow(title: "录制", detail: preferences.settings.audioSource.detail) {
                if AudioCapture.supportsSystemAudio {
                    MenuPicker(items: AudioSourceChoice.allCases, selection: $preferences.settings.audioSource) { $0.title }
                } else {
                    Text("麦克风").font(Theme.bodyFont).foregroundStyle(Theme.secondaryText)
                }
            }
            #if os(macOS)
            if preferences.settings.audioSource == .app {
                RowDivider()
                AppPickerRow()
            }
            #endif
        }

        SettingsGroup(title: "多人识别") {
            SettingsRow(title: "标注说话人", detail: "录音中点名字即可命名") {
                HUDToggle(isOn: $preferences.settings.speakerLabeling)
            }
            if !models.installed.contains(.speakerEmbedding) {
                RowDivider()
                SettingsRow(title: "说话人声纹模型", detail: ModelKind.speakerEmbedding.approximateSize) { ModelActionButton(kind: .speakerEmbedding) }
            }
            RowDivider()
            SettingsRow(title: "预期人数") {
                HUDStepper(
                    text: preferences.settings.expectedSpeakers == 0 ? "自动" : "\(preferences.settings.expectedSpeakers) 人",
                    value: $preferences.settings.expectedSpeakers, range: 0...10
                )
            }
        }

        SettingsGroup(title: "实时翻译") {
            SettingsRow(title: "翻译每句话") {
                HUDToggle(isOn: $preferences.settings.translation.enabled)
            }
            if preferences.settings.translation.enabled {
                RowDivider()
                SettingsRow(title: "译文") {
                    MenuPicker(items: TranslationTarget.allCases, selection: $preferences.settings.translation.target) { $0.title }
                }
                RowDivider()
                SettingsRow(title: "引擎") {
                    MenuPicker(items: TranslationEngineChoice.allCases, selection: $preferences.settings.translation.engine) { $0.title }
                }
                if OnDeviceTranslation.isAvailable && preferences.settings.translation.engine != .cloud {
                    RowDivider()
                    SettingsRow(title: "离线翻译语言", detail: "首次使用需下载") {
                        PrepareTranslationButton(target: preferences.settings.translation.target)
                    }
                }
            }
        }

        #if os(macOS)
        SettingsGroup(title: "录音条") {
            SettingsRow(title: "始终在最前") {
                HUDToggle(isOn: $preferences.settings.floatOnTop)
            }
        }
        #endif
    }
}

#if os(macOS)
private struct AppPickerRow: View {
    @Environment(Preferences.self) private var preferences
    @State private var apps: [RecordableApps.App] = []

    var body: some View {
        SettingsRow(title: "应用") {
            HStack(spacing: 4) {
                let none = RecordableApps.App(bundleID: "", name: "请选择")
                let all = [none] + apps
                MenuPicker(
                    items: all,
                    selection: Binding(
                        get: { all.first { $0.bundleID == preferences.settings.audioAppBundleID } ?? none },
                        set: { preferences.settings.audioAppBundleID = $0.bundleID.isEmpty ? nil : $0.bundleID }
                    )
                ) { $0.name }
                IconButton(systemName: "arrow.clockwise", help: "刷新正在运行的应用", size: 24) {
                    apps = RecordableApps.running()
                }
            }
        }
        .onAppear { apps = RecordableApps.running() }
    }
}
#endif

// MARK: - 识别

private struct RecognitionSettings: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var models

    var body: some View {
        @Bindable var preferences = preferences
        let plan = EnginePlan.make(settings: preferences.settings, local: models.engines, hasAPIKey: preferences.hasAPIKey)
        SettingsGroup(title: "当前", footer: plan.problem) {
            SettingsRow(title: "实时字幕", detail: nil) {
                Text(plan.streaming).font(Theme.bodyFont).foregroundStyle(Theme.secondaryText)
            }
            RowDivider()
            SettingsRow(title: "句末纠错") {
                Text(plan.corrector ?? "不纠错").font(Theme.bodyFont).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }

        SettingsGroup(title: "本机引擎", footer: "「自动」会选用已安装的最准模型。") {
            SettingsRow(title: "实时字幕") {
                MenuPicker(items: StreamingEngineChoice.allCases, selection: $preferences.settings.streamingEngine) { $0.title }
            }
            RowDivider()
            SettingsRow(title: "句末纠错") {
                MenuPicker(items: CorrectorChoice.allCases.filter { $0 != .qwen3ASRLarge || LocalEngines.supportsLlama },
                           selection: $preferences.settings.corrector) { $0.title }
            }
        }

        SettingsGroup(title: "专业词汇",
                      footer: "当事人、公司、人名等专有名词被写成同音或近音字时自动改回（3 个字以上才按近音）；固定的错误可写成「备诉=反诉」精确替换。用 Fun-ASR-Nano 纠错时，前 20 个还会作为热词。") {
            SettingsRow(title: "法律术语校正", detail: "如「新政」→「心证」、「权力瑕疵」→「权利瑕疵」") {
                HUDToggle(isOn: $preferences.settings.legalTerms)
            }
            RowDivider()
            VocabularyField()
            RowDivider()
            ContextNoteField()
        }

        SettingsGroup(title: "断句", footer: "说话慢、常停顿可把「停顿」调大。") {
            SettingsRow(title: "停顿") {
                HUDStepper(text: "\(preferences.settings.silenceMs) 毫秒", value: $preferences.settings.silenceMs, range: 300...2000, step: 100)
            }
            RowDivider()
            SettingsRow(title: "单句最长") {
                HUDStepper(text: "\(preferences.settings.maxUtteranceSeconds) 秒", value: $preferences.settings.maxUtteranceSeconds, range: 8...30)
            }
        }
    }
}

/// What the recording is about, told to Qwen3-ASR 1.7B before every sentence (CapsWriter's context).
private struct ContextNoteField: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        TextField("", text: $preferences.settings.contextNote,
                  prompt: Text("背景说明（可选，Qwen3-ASR 会参考）：如 买卖合同纠纷，原告某机械公司，被告成都航天，争议焦点是合同解除").foregroundStyle(Theme.tertiaryText),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...5)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }
}

/// The user's own terms, one text field; saved as typed, without rewriting what's being typed.
private struct VocabularyField: View {
    @Environment(Preferences.self) private var preferences
    @State private var draft = ""

    var body: some View {
        TextField("", text: $draft, prompt: Text("逗号或换行分隔：长城汽车，成都航天，备诉=反诉").foregroundStyle(Theme.tertiaryText),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...4)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .onAppear { draft = preferences.settings.vocabulary.joined(separator: "，") }
            .onChange(of: draft) { _, text in
                preferences.settings.vocabulary = AppSettings.parseVocabulary(text)
            }
    }
}

// MARK: - 模型

private struct ModelSettings: View {
    @Environment(ModelManager.self) private var models
    @State private var removing: ModelKind?
    #if os(iOS)
    @State private var importing = false
    #endif

    private let groups: [(String, [ModelKind])] = [
        ("实时字幕", [.streamingXASRFast, .streamingXASR, .streamingZipformer]),
        ("句末纠错", (LocalEngines.supportsLlama ? [.qwen3ASRLarge] : [])
            + [.funASRNano, .paraformer, .senseVoiceANE, .senseVoice, .fireRed, .qwen3ASR, .punctuation]),
        ("多人", [.speakerEmbedding]),
    ]

    var body: some View {
        if let error = models.lastError {
            MessageRow(text: error, isError: true) { models.lastError = nil }
        } else if let notice = models.lastNotice {
            MessageRow(text: notice) { models.lastNotice = nil }
        }
        ForEach(groups, id: \.0) { title, kinds in
            SettingsGroup(title: title) {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    if index > 0 { RowDivider() }
                    ModelRow(kind: kind, removing: $removing)
                }
            }
        }
        if let kind = removing {
            InlineConfirm(prompt: "删除「\(kind.title)」？", confirmTitle: "删除") {
                models.remove(kind)
                removing = nil
            } onCancel: {
                removing = nil
            }
        }
        HStack(spacing: 8) {
            Button {
                #if os(macOS)
                FileSaver.chooseFolder { models.importFolder($0) }
                #else
                importing = true
                #endif
            } label: {
                Label("导入模型文件夹", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.hud(.secondary))
            #if os(macOS)
            Button {
                try? FileManager.default.createDirectory(at: models.locator.root, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([models.locator.root])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .buttonStyle(.hud(.quiet))
            #endif
        }
        #if os(iOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { models.importFolder(url) }
        }
        #endif
        Text("模型来自 sherpa-onnx 官方发布与 FluidAudio，仅在点击下载时联网。")
            .font(Theme.metaFont)
            .foregroundStyle(Theme.tertiaryText)
    }
}

private struct ModelRow: View {
    let kind: ModelKind
    @Binding var removing: ModelKind?
    @Environment(ModelManager.self) private var models

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: kind.title, detail: "\(kind.role) · \(kind.approximateSize)") {
                if models.installed.contains(kind) && !models.isBusy(kind) {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.6))
                        Menu {
                            Button("重新下载") { models.install(kind) }
                            Button("删除…", role: .destructive) { removing = kind }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                } else {
                    ModelActionButton(kind: kind)
                }
            }
            if let progress = models.progress[kind] {
                ProgressView(value: progress.fraction) {
                    Text(progress.label).font(Theme.microFont).foregroundStyle(Theme.tertiaryText)
                }
                .progressViewStyle(.linear)
                .tint(Theme.record)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }
}

/// Download / cancel button for one model.
struct ModelActionButton: View {
    let kind: ModelKind
    @Environment(ModelManager.self) private var models

    var body: some View {
        if models.isBusy(kind) {
            Button("取消") { models.cancel(kind) }.buttonStyle(.hud(.quiet))
        } else {
            Button("下载") { models.install(kind) }.buttonStyle(.hud(.secondary))
        }
    }
}

// MARK: - 云端

private struct CloudSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var draft = ""
    @State private var status: String?

    var body: some View {
        SettingsGroup(title: "阿里云百炼",
                      footer: "用于混合 / 纯云端识别和云端翻译。Key 保存在系统钥匙串；纯离线模式不会联网。") {
            SettingsRow(title: "API Key", detail: status ?? (preferences.hasAPIKey ? "已保存" : "未填写")) {
                if preferences.hasAPIKey {
                    Button("清除") { save("") }.buttonStyle(.hud(.quiet))
                }
            }
            RowDivider()
            HStack(spacing: 8) {
                SecureField("", text: $draft, prompt: Text(preferences.hasAPIKey ? "输入新的 Key 以替换" : "sk-…").foregroundStyle(Theme.tertiaryText))
                    .textFieldStyle(.plain)
                    .font(Theme.bodyFont)
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit { save(draft) }
                Button("保存") { save(draft) }
                    .buttonStyle(.hud(.primary))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        Link(destination: URL(string: "https://bailian.console.aliyun.com/?apiKey=1")!) {
            Label("获取 API Key", systemImage: "arrow.up.right")
                .font(Theme.metaFont)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func save(_ value: String) {
        do {
            try preferences.setAPIKey(value)
            draft = ""
            status = value.isEmpty ? "已清除" : "已保存到钥匙串"
        } catch {
            status = error.localizedDescription
        }
    }
}
