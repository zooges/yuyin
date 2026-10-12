import SwiftUI
import YuyinCore

struct SpeakerOption: Identifiable, Hashable {
    let index: Int
    let label: String
    var id: Int { index }
}

/// A speaker as a colored dot and a name.
struct SpeakerName: View {
    let index: Int?
    let label: String?
    var font: Font = Theme.microFont

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.speakerColor(index)).frame(width: 6, height: 6)
            Text(label ?? "未识别")
                .font(font)
                .foregroundStyle(index == nil ? Theme.tertiaryText : Theme.speakerColor(index))
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// The sentence still being heard: speaker not known yet.
struct PendingSpeaker: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.tertiaryText)
                .frame(width: 6, height: 6)
                .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
            Text("识别中").font(Theme.microFont).foregroundStyle(Theme.tertiaryText)
        }
        .fixedSize()
    }
}

/// A sentence's speaker. Tap to name that speaker or to say the sentence was someone else's.
struct SpeakerTag: View {
    let utterance: Utterance
    let label: String?
    let options: [SpeakerOption]
    let onRename: (Int, String) -> Void
    let onReassign: (Int?) -> Void
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            SpeakerName(index: utterance.speakerIndex, label: label)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击命名或更正说话人")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            SpeakerEditor(
                current: utterance.speakerIndex,
                currentLabel: label,
                options: options,
                onRename: onRename,
                onReassign: onReassign
            )
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Name a speaker (same name as another speaker = merge) and/or move one sentence.
struct SpeakerEditor: View {
    let current: Int?
    let currentLabel: String?
    let options: [SpeakerOption]
    let onRename: (Int, String) -> Void
    var onReassign: ((Int?) -> Void)?
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let current {
                VStack(alignment: .leading, spacing: 8) {
                    Text("命名说话人").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        TextField(currentLabel ?? SpeakerBook.defaultLabel(current), text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save(current) }
                        Button("保存") { save(current) }
                            .keyboardShortcut(.defaultAction)
                    }
                    Text("与已有名字相同会合并为同一人").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let onReassign {
                if current != nil { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Text(current == nil ? "这句话是谁说的？" : "这句其实是")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(options.filter { $0.index != current }) { option in
                        Button {
                            onReassign(option.index)
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.speakerColor(option.index)).frame(width: 7, height: 7)
                                Text(option.label)
                            }
                            .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        onReassign(nil)
                        dismiss()
                    } label: {
                        Label("新的说话人", systemImage: "plus").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            if let current, let currentLabel, currentLabel != SpeakerBook.defaultLabel(current) {
                name = currentLabel
            }
        }
    }

    private func save(_ index: Int) {
        onRename(index, name)
        dismiss()
    }
}

/// All speakers of a recording; tap one to name it.
struct SpeakerRoster: View {
    let options: [SpeakerOption]
    let onRename: (Int, String) -> Void
    @State private var editing: SpeakerOption?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(options) { option in
                    Button { editing = option } label: {
                        SpeakerName(index: option.index, label: option.label, font: .system(size: 12, weight: .medium))
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击命名")
                    .popover(isPresented: Binding(
                        get: { editing == option },
                        set: { if !$0 { editing = nil } }
                    ), arrowEdge: .bottom) {
                        SpeakerEditor(current: option.index, currentLabel: option.label, options: options, onRename: onRename)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
        }
    }
}
