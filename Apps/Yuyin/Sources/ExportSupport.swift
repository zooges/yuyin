import SwiftUI
import UniformTypeIdentifiers
import YuyinCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .plainText: return .plainText
        case .srt: return UTType(filenameExtension: "srt", conformingTo: .plainText) ?? .plainText
        case .markdown: return UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        }
    }
}

extension Meeting {
    /// `title.ext`, without the path separators "/" and ":" that titles often contain
    /// ("录音 10月11日 14:30", "Q3/Q4 规划") and save panels reject or treat as folders.
    func exportFileName(_ format: ExportFormat) -> String {
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(name).\(format.fileExtension)"
    }

    /// The export as a temporary file named after the recording, for handing to other apps
    /// (WeChat, B&Y AGENT, … take files, not text).
    func exportFile(_ format: ExportFormat, utterances subset: [Utterance]?, includeTranslation: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(exportFileName(format))
        try export(format, utterances: subset, includeTranslation: includeTranslation)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Export a recording to txt / SRT / Markdown (speaker names, optional translations), send it to
/// another app, or copy it.
struct ExportMenu: View {
    let meeting: Meeting
    var subset: [Utterance]?
    var style: HUDButtonStyle.Kind = .secondary

    @State private var includeTranslation = true
    #if os(macOS)
    @State private var anchor = ShareAnchor()
    #else
    @State private var document = TranscriptDocument(text: "")
    @State private var format: ExportFormat = .plainText
    @State private var exporting = false
    #endif

    private var hasTranslation: Bool { meeting.utterances.contains { $0.translation != nil } }

    var body: some View {
        Menu {
            ForEach(ExportFormat.allCases) { item in
                Button("导出 \(item.title)…") { export(item) }
            }
            Menu("发送到其他应用") {
                ForEach(ExportFormat.allCases) { item in
                    Button(item.title) { share(item) }
                }
            }
            if hasTranslation {
                Divider()
                Toggle("包含译文", isOn: $includeTranslation)
            }
            Divider()
            Button("复制全文") {
                Clipboard.copy(meeting.export(.plainText, utterances: subset, includeTranslation: includeTranslation))
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.hud(style))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(meeting.utterances.isEmpty)
        #if os(macOS)
        .background(ShareAnchorView(anchor: anchor))
        #else
        .fileExporter(isPresented: $exporting, document: document, contentType: format.contentType,
                      defaultFilename: meeting.exportFileName(format)) { _ in }
        #endif
    }

    private func share(_ item: ExportFormat) {
        guard let url = try? meeting.exportFile(item, utterances: subset, includeTranslation: includeTranslation) else { return }
        #if os(macOS)
        Sharing.share(url, from: anchor.view)
        #else
        Sharing.share(url)
        #endif
    }

    private func export(_ item: ExportFormat) {
        let text = meeting.export(item, utterances: subset, includeTranslation: includeTranslation)
        #if os(macOS)
        FileSaver.save(text: text, name: meeting.exportFileName(item), type: item.contentType)
        #else
        format = item
        document = TranscriptDocument(text: text)
        exporting = true
        #endif
    }
}

#if os(macOS)
/// Standalone save / open panels (the bar is a borderless panel, so no sheets).
@MainActor
enum FileSaver {
    static func save(text: String, name: String, type: UTType) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.level = .floating
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func chooseFolder(completion: @escaping (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.level = .floating
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
}

/// The system share popover: Mail, AirDrop, and every app with a share extension (WeChat, …).
@MainActor
enum Sharing {
    static func share(_ url: URL, from view: NSView?) {
        guard let view else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// The view a share popover points at: a menu item's action has no view of its own.
final class ShareAnchor {
    weak var view: NSView?
}

struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
#else
/// The system share sheet: WeChat, Files, AirDrop, and every app with a share extension.
@MainActor
enum Sharing {
    static func share(_ url: URL) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad shows it as a popover, which needs a source.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { ExportFormat.allCases.map(\.contentType) }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
