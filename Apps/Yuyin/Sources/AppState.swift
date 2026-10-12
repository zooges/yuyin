import Foundation
import Observation
import YuyinCore
import YuyinLocal

/// Settings (UserDefaults) + cloud key (Keychain).
@Observable
@MainActor
final class Preferences {
    private let store: SettingsStore
    private let secrets: SecretStore

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            let next = settings
            store.update { $0 = next }
        }
    }

    private(set) var hasAPIKey: Bool

    init(secrets: SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        store = SettingsStore(secrets: secrets)
        settings = store.settings
        hasAPIKey = !(secrets.read(.funASRKey) ?? "").isEmpty
    }

    var apiKey: String { secrets.read(.funASRKey) ?? "" }

    func setAPIKey(_ value: String) throws {
        try secrets.write(value, for: .funASRKey)
        hasAPIKey = !(secrets.read(.funASRKey) ?? "").isEmpty
    }
}

@Observable
@MainActor
final class ModelManager {
    let locator: ModelLocator
    let engines: LocalEngines
    private let installer: ModelInstaller

    private(set) var installed: Set<ModelKind> = []
    private(set) var progress: [ModelKind: InstallProgress] = [:]
    private var tasks: [ModelKind: Task<Void, Never>] = [:]
    var lastError: String?
    var lastNotice: String?

    init(locator: ModelLocator = .standard) {
        self.locator = locator
        engines = LocalEngines(locator: locator)
        installer = ModelInstaller(locator: locator)
        refresh()
        // A better model replaced one the user already installed: fetch it quietly.
        for kind in ModelKind.allCases where locator.isOutdated(kind) {
            install(kind)
        }
    }

    func refresh() {
        installed = Set(ModelKind.allCases.filter { locator.isInstalled($0) })
    }

    func isBusy(_ kind: ModelKind) -> Bool { tasks[kind] != nil }

    func install(_ kind: ModelKind) {
        guard tasks[kind] == nil else { return }
        // Paraformer / FireRed output no punctuation; fetch the small punctuation model with them.
        if (kind == .paraformer || kind == .fireRed) && !installed.contains(.punctuation) {
            install(.punctuation)
        }
        progress[kind] = InstallProgress(phase: .downloading, fraction: 0)
        tasks[kind] = Task {
            do {
                try await installer.install(kind) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.tasks[kind] != nil else { return }
                        self.progress[kind] = p
                    }
                }
                lastNotice = "\(kind.title) 已安装"
            } catch is CancellationError {
                // User cancelled.
            } catch {
                lastError = "\(kind.title)：\(error.localizedDescription)"
            }
            tasks[kind] = nil
            progress[kind] = nil
            refresh()
        }
    }

    func cancel(_ kind: ModelKind) {
        tasks[kind]?.cancel()
    }

    func remove(_ kind: ModelKind) {
        Task {
            do {
                try await installer.remove(kind)
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }

    func importFolder(_ url: URL) {
        Task {
            do {
                let kind = try await installer.importFolder(url)
                lastNotice = "已导入：\(kind.title)"
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }
}

@Observable
@MainActor
final class MeetingLibrary {
    let store: MeetingStore
    private(set) var meetings: [Meeting] = []
    /// Meetings whose recording was cut short (app quit or crashed mid-session).
    private(set) var interrupted: Set<UUID> = []
    var lastError: String?
    private var loaded = false

    init(root: URL) {
        store = MeetingStore(root: root)
    }

    /// Runs once per process (each new window's `.task` calls it).
    func load(legacyFile: URL?) async {
        guard !loaded else { return }
        loaded = true
        if let legacyFile {
            do {
                try await store.importLegacy(from: legacyFile)
            } catch {
                lastError = "导入旧版记录失败：\(error.localizedDescription)"
            }
        }
        do {
            var loaded = try await store.loadAll()
            for index in loaded.indices where loaded[index].isRecording {
                loaded[index].isRecording = false
                interrupted.insert(loaded[index].id)
                try? await store.save(loaded[index])
            }
            meetings = loaded
        } catch {
            lastError = "读取历史记录失败：\(error.localizedDescription)"
        }
    }

    func meeting(_ id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func hasAudio(_ id: UUID) -> Bool {
        store.hasAudio(id)
    }

    func save(_ meeting: Meeting) async {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
        do {
            try await store.save(meeting)
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
    }

    func rename(_ id: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var meeting = meeting(id), !trimmed.isEmpty else { return }
        meeting.title = trimmed
        await save(meeting)
    }

    /// Same semantics as during recording: an existing name merges the two speakers.
    func renameSpeaker(_ index: Int, to name: String, in id: UUID) async {
        guard var meeting = meeting(id) else { return }
        var book = meeting.speakerBook
        book.rename(index, to: name)
        meeting.utterances = meeting.utterances.map(book.resolve)
        meeting.speakerNames = book.names
        await save(meeting)
    }

    func reassign(_ utteranceID: UUID, to index: Int?, in id: UUID) async {
        guard var meeting = meeting(id) else { return }
        var book = meeting.speakerBook
        book.reassign(utteranceID, to: index ?? book.nextIndex(after: meeting.utterances))
        meeting.utterances = meeting.utterances.map(book.resolve)
        await save(meeting)
    }

    func delete(_ id: UUID) async {
        meetings.removeAll { $0.id == id }
        interrupted.remove(id)
        do {
            try await store.delete(id)
        } catch {
            lastError = "删除失败：\(error.localizedDescription)"
        }
    }

    /// Whole-recording diarization; returns the number of speakers found.
    /// Labels every sentence again from the saved audio, the way the live pass does it (the
    /// voiced part of each sentence, clustered in time order) but with the current model.
    /// Measured on two AMI meetings this beats whole-recording pyannote diarization
    /// (95.7% / 90.1% vs 61–91% speaker accuracy) and fixes recordings made before v0.8.
    func analyzeSpeakers(_ id: UUID, engines: LocalEngines, expectedSpeakers: Int) async throws -> Int {
        guard let original = meeting(id) else { return 0 }
        guard let labeler = engines.makeSpeakerLabeler() else { throw ASRError.modelMissing("说话人声纹") }
        let url = store.audioURL(for: id)
        try await labeler.prepare(expectedSpeakers: expectedSpeakers)
        var map: [UUID: Int?] = [:]
        let pad = 100
        for u in original.utterances.sorted(by: { $0.startMs < $1.startMs }) {
            guard u.status == .final, TextFilter.isMeaningful(u.displayText) else { continue }
            let range = AudioSpec.samples(forMilliseconds: max(0, u.startMs - pad))..<AudioSpec.samples(forMilliseconds: (u.endMs ?? u.startMs) + pad)
            let clip = try await Task.detached(priority: .userInitiated) { try WAVFile.read(url, range: range) }.value
            guard clip.count >= AudioSpec.samples(forMilliseconds: 600) else {
                map[u.id] = .some(nil)
                continue
            }
            map[u.id] = try await labeler.assign(clip, speechMs: AudioSpec.milliseconds(forSamples: clip.count) - 2 * pad)
        }
        await labeler.shutdown()

        // The meeting may have been renamed or deleted during the analysis.
        guard var meeting = meeting(id) else { return 0 }
        meeting.speakerNames = SpeakerMapping.transferNames(meeting.speakerNames, from: meeting.utterances, to: map)
        for index in meeting.utterances.indices {
            if let speaker = map[meeting.utterances[index].id] {
                meeting.utterances[index].speakerIndex = speaker
            }
        }
        await save(meeting)
        return Set(map.values.compactMap { $0 }).count
    }
}
