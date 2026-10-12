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

/// Export a recording to txt / SRT / Markdown (speaker names, optional translations), or copy it.
struct ExportMenu: View {
    let meeting: Meeting
    var subset: [Utterance]?
    var style: HUDButtonStyle.Kind = .secondary

    @State private var includeTranslation = true
    #if os(iOS)
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
        #if os(iOS)
        .fileExporter(isPresented: $exporting, document: document, contentType: format.contentType,
                      defaultFilename: "\(meeting.title).\(format.fileExtension)") { _ in }
        #endif
    }

    private func export(_ item: ExportFormat) {
        let text = meeting.export(item, utterances: subset, includeTranslation: includeTranslation)
        #if os(macOS)
        FileSaver.save(text: text, name: "\(meeting.title).\(item.fileExtension)", type: item.contentType)
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
#else
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
