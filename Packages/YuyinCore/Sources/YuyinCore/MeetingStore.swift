import Foundation

public struct Meeting: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var mode: TranscriptMode?
    public var engines: String?
    public var utterances: [Utterance]
    /// User-given speaker names by speaker index.
    public var speakerNames: [Int: String]
    public var durationMs: Int
    /// True while the session is running; a meeting still marked on launch was interrupted.
    public var isRecording: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        mode: TranscriptMode? = nil,
        engines: String? = nil,
        utterances: [Utterance] = [],
        speakerNames: [Int: String] = [:],
        durationMs: Int = 0,
        isRecording: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.mode = mode
        self.engines = engines
        self.utterances = utterances
        self.speakerNames = speakerNames
        self.durationMs = durationMs
        self.isRecording = isRecording
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        mode = try? c.decodeIfPresent(TranscriptMode.self, forKey: .mode)
        engines = try c.decodeIfPresent(String.self, forKey: .engines)
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        speakerNames = (try? c.decodeIfPresent([Int: String].self, forKey: .speakerNames)) ?? [:]
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
            ?? utterances.compactMap(\.endMs).max() ?? 0
        isRecording = try c.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
    }

    public var plainText: String {
        utterances.map(\.displayText).filter(TextFilter.isMeaningful).joined(separator: " ")
    }

    public var speakerIndices: [Int] {
        SpeakerBook().speakers(in: utterances)
    }

    public var speakerBook: SpeakerBook { SpeakerBook(names: speakerNames) }

    public func export(_ format: ExportFormat, utterances subset: [Utterance]? = nil, includeTranslation: Bool = true) -> String {
        TranscriptExporter.export(
            subset ?? utterances, format: format, title: title,
            speakerNames: speakerNames, includeTranslation: includeTranslation
        )
    }

    public static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "录音 \(formatter.string(from: date))"
    }
}

/// One directory per meeting: `<root>/<id>/meeting.json` + optional `audio.wav`.
public actor MeetingStore {
    public nonisolated let root: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public init(root: URL) {
        self.root = root
    }

    public nonisolated func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public nonisolated func audioURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("audio.wav")
    }

    public nonisolated func hasAudio(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: id).path)
    }

    public func loadAll() throws -> [Meeting] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dirs = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        return dirs.compactMap { dir in
            let file = dir.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ meeting: Meeting) throws {
        let dir = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(meeting)
        try data.write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let dir = directory(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Imports v0.1's single `meetings.json`, then renames it so it is imported only once.
    @discardableResult
    public func importLegacy(from file: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let data = try Data(contentsOf: file)
        let legacy = try JSONDecoder().decode([Meeting].self, from: data)
        var imported = 0
        for var meeting in legacy {
            meeting.utterances.removeAll { !TextFilter.isMeaningful($0.displayText) }
            guard !meeting.utterances.isEmpty,
                  !FileManager.default.fileExists(atPath: directory(for: meeting.id).path)
            else { continue }
            meeting.isRecording = false
            try save(meeting)
            imported += 1
        }
        let done = file.deletingPathExtension().appendingPathExtension("migrated.json")
        try? FileManager.default.removeItem(at: done)
        try FileManager.default.moveItem(at: file, to: done)
        return imported
    }
}
