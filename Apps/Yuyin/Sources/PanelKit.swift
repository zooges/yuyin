import SwiftUI
import YuyinCore

// MARK: - Surfaces

/// Dark translucent surface shared by the bar and every card.
struct HUDSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color(white: 0.06).opacity(0.62)))
            }
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
            .clipShape(shape)
            // Soft and short: it must fade out inside the window margin, or the cut-off shadow
            // shows as a dark frame around the panel (`BarLayout.margin`).
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

extension View {
    func hudCard() -> some View {
        modifier(HUDSurface(shape: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)))
    }

    func hudCapsule() -> some View {
        modifier(HUDSurface(shape: Capsule()))
    }
}

// MARK: - Buttons

/// Round icon button (bar and card headers).
struct IconButton: View {
    let systemName: String
    var help: String
    var isActive = false
    var size: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.secondaryText)
                .frame(width: size, height: size)
                .background(Circle().fill(isActive ? Theme.fillActive : (hovering ? Theme.fillHover : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Capsule text button. `.primary` = coral, `.secondary` = subtle fill, `.quiet` = text only.
struct HUDButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary || kind == .destructive ? .semibold : .medium))
            .padding(.horizontal, kind == .quiet ? 6 : 14)
            .padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .destructive: return .white
        case .secondary: return Theme.textPrimary
        case .quiet: return Theme.secondaryText
        }
    }

    private var background: Color {
        switch kind {
        case .primary, .destructive: return Theme.record
        case .secondary: return Theme.fillHover
        case .quiet: return .clear
        }
    }
}

extension ButtonStyle where Self == HUDButtonStyle {
    static var hud: HUDButtonStyle { HUDButtonStyle() }
    static func hud(_ kind: HUDButtonStyle.Kind) -> HUDButtonStyle { HUDButtonStyle(kind: kind) }
}

/// The record / stop button with a breathing ring while listening.
struct RecordButton: View {
    let isRecording: Bool
    let isListening: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isListening {
                    // Scoped to the ring: a repeating withAnimation in onAppear would also animate layout.
                    Circle()
                        .stroke(Theme.record.opacity(0.5), lineWidth: 2)
                        .frame(width: 38, height: 38)
                        .phaseAnimator([false, true]) { ring, expanded in
                            ring.scaleEffect(expanded ? 1.3 : 1).opacity(expanded ? 0 : 0.9)
                        } animation: { expanded in
                            expanded ? .easeOut(duration: 1.6) : .linear(duration: 0)
                        }
                }
                Circle()
                    .fill(Theme.record)
                    .frame(width: 38, height: 38)
                    .shadow(color: Theme.record.opacity(0.4), radius: 8)
                if isRecording {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(.white)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "结束录音" : "开始录音")
    }
}

/// Live input level as a small waveform.
struct Waveform: View {
    var level: Float
    var active: Bool
    private let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.8, 0.55, 0.9, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? Theme.textPrimary : Theme.tertiaryText)
                    .frame(width: 3, height: height(for: i))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func height(for i: Int) -> CGFloat {
        guard active else { return 4 }
        let l = CGFloat(min(1, max(0, level)))
        return 4 + (18 * l * weights[i])
    }
}

// MARK: - Card structure

/// Title row of a card, with optional back / close and trailing actions.
struct CardHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var back: (() -> Void)?
    var close: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                IconButton(systemName: "chevron.left", help: "返回", size: 28, action: back)
                    .padding(.leading, -6)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.titleFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(Theme.metaFont).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
            if let close {
                IconButton(systemName: "xmark", help: "收起", size: 28, action: close)
                    .padding(.trailing, -6)
            }
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil, close: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, back: back, close: close) { EmptyView() }
    }
}

/// Segmented tabs drawn in the HUD style.
struct TabSwitcher<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    withAnimation(.spring(duration: 0.25)) { selection = tab }
                } label: {
                    Text(title(tab))
                        .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Theme.textPrimary : Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == tab {
                                Capsule().fill(Theme.fillActive).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.fill))
    }
}

/// A group of settings rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(Theme.microFont).foregroundStyle(Theme.tertiaryText).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous).fill(Theme.fill))
            if let footer {
                Text(footer)
                    .font(Theme.metaFont)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(Theme.metaFont).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct RowDivider: View {
    var inset: CGFloat = 12
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, inset)
    }
}

struct HUDSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.tertiaryText))
                .textFieldStyle(.plain)
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.fill))
    }
}

// MARK: - Transcript

/// One sentence in a list (expanded live view, saved recordings).
struct TranscriptRow<Speaker: View>: View {
    let utterance: Utterance
    var translationPending = false
    @ViewBuilder var speaker: () -> Speaker

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                speaker()
                Text(Format.duration(utterance.startMs))
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
                if utterance.status == .pendingCorrection {
                    ProgressView().controlSize(.mini).tint(Theme.tertiaryText)
                }
            }
            Text(utterance.displayText.isEmpty ? "…" : utterance.displayText)
                .font(Theme.transcriptFont)
                .lineSpacing(3)
                .foregroundStyle(utterance.status == .final ? Theme.textPrimary : Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let translation = utterance.translation {
                Text(translation)
                    .font(Theme.translationFont)
                    .lineSpacing(2)
                    .foregroundStyle(Theme.translation)
                    .textSelection(.enabled)
            } else if translationPending {
                Text("翻译中…").font(Theme.metaFont).foregroundStyle(Theme.tertiaryText)
            }
            if utterance.status == .failed, let error = utterance.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(Theme.metaFont).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 10)
    }
}

/// Inline confirmation instead of a system alert.
struct InlineConfirm: View {
    let prompt: String
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(prompt).font(Theme.bodyFont).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 6)
            Button("取消", action: onCancel).buttonStyle(.hud(.quiet))
            Button(confirmTitle, action: onConfirm).buttonStyle(.hud(.destructive))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous).fill(Theme.record.opacity(0.12)))
    }
}

/// Slim message line at the top of a card.
struct MessageRow: View {
    let text: String
    var isError = false
    var actionTitle: String?
    var action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isError ? Color.orange : Theme.secondaryText)
            Text(text)
                .font(Theme.metaFont)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.hud(.secondary))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.groupRadius, style: .continuous).fill(Theme.fill))
    }
}
