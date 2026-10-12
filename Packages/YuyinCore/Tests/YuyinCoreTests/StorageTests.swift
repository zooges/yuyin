import XCTest
@testable import YuyinCore

final class StorageTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yuyin-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMeetingRoundTripAndDelete() async throws {
        let store = MeetingStore(root: tmp)
        let u = Utterance(startMs: 0, endMs: 900, partial: "你好", finalText: "你好。", status: .final, provider: "x", speakerIndex: 1)
        let older = Meeting(title: "A", createdAt: Date(timeIntervalSince1970: 10), utterances: [u])
        let newer = Meeting(title: "B", createdAt: Date(timeIntervalSince1970: 20), mode: .hybrid)
        try await store.save(older)
        try await store.save(newer)
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.map(\.title), ["B", "A"])
        XCTAssertEqual(loaded[1], older)
        try await store.delete(older.id)
        let after = try await store.loadAll()
        XCTAssertEqual(after.map(\.id), [newer.id])
    }

    func testImportsLegacyMeetingsJSON() async throws {
        // Shape written by v0.1 (default JSONEncoder date strategy, speakerLabel field).
        let legacy = """
        [{"id":"6CA94099-B35E-47BB-9D92-D83327F900DD","title":"会议 10月11日 18:55","createdAt":813408944.755019,
          "utterances":[{"status":"final","finalText":"。","provider":"sherpa-sensevoice","id":"13598FAB-A1D7-447B-B68D-20BEA9942673","startMs":10399,"partial":"","endMs":11832}]},
         {"id":"7CA94099-B35E-47BB-9D92-D83327F900DD","title":"会议 2","createdAt":813408900,
          "utterances":[{"status":"final","finalText":"今天开会。","provider":"sherpa-sensevoice","id":"23598FAB-A1D7-447B-B68D-20BEA9942673","startMs":100,"partial":"今天开会","endMs":1800,"speakerIndex":0,"speakerLabel":"说话人 1"}]}]
        """
        let file = tmp.appendingPathComponent("meetings.json")
        try Data(legacy.utf8).write(to: file)
        let store = MeetingStore(root: tmp.appendingPathComponent("Meetings"))
        let imported = try await store.importLegacy(from: file)
        XCTAssertEqual(imported, 1, "punctuation-only meeting is skipped")
        let all = try await store.loadAll()
        XCTAssertEqual(all.first?.utterances.first?.displayText, "今天开会。")
        XCTAssertEqual(all.first?.durationMs, 1800)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let again = try await store.importLegacy(from: file)
        XCTAssertEqual(again, 0)
    }

    func testLegacySettingsMigrateAndAPIKeyMovesToSecretStore() throws {
        let defaults = UserDefaults(suiteName: "yuyin-tests-\(UUID())")!
        let legacy = """
        {"mode":"hybrid","apiKey":"sk-123","silenceMs":900,"preferSherpaWhenAvailable":true,
         "preferFireRedCorrector":true,"enableSpeakerLabeling":true,"expectedSpeakerCount":3,"qualityProfile":"accurate"}
        """
        defaults.set(Data(legacy.utf8), forKey: "yuyin.settings")
        let secrets = InMemorySecretStore()
        let store = SettingsStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(store.settings.mode, .hybrid)
        XCTAssertEqual(store.settings.silenceMs, 900)
        XCTAssertEqual(store.settings.corrector, .auto, "the retired FireRed choice falls back to automatic")
        XCTAssertEqual(store.settings.streamingEngine, .auto)
        XCTAssertTrue(store.settings.speakerLabeling)
        XCTAssertEqual(store.settings.expectedSpeakers, 3)
        XCTAssertEqual(secrets.read(.funASRKey), "sk-123")
        let persisted = String(data: defaults.data(forKey: "yuyin.settings")!, encoding: .utf8)!
        XCTAssertFalse(persisted.contains("sk-123"), "plain-text key is scrubbed from UserDefaults")
    }

    func testWAVRoundTripAndUnfinalizedHeader() throws {
        let url = tmp.appendingPathComponent("a.wav")
        let samples = Signal.tone(ms: 300)
        let writer = try WAVFileWriter(url: url)
        writer.append(Array(samples[0..<1000]))
        // Not closed yet: header still says 0 bytes, reader must use the file length.
        writer.append(Array(samples[1000...]))
        let unfinalized = try WAVFile.read(url)
        XCTAssertEqual(unfinalized.count, samples.count)
        writer.close()
        let read = try WAVFile.read(url, range: 100..<200)
        XCTAssertEqual(read.count, 100)
        XCTAssertEqual(read[0], samples[100], accuracy: 1e-4)
        XCTAssertEqual(WAVFile.encode(samples).count, 44 + samples.count * 2)
    }

    func testLegacyKeyIsKeptWhenKeychainWriteFails() {
        final class FailingSecrets: SecretStore, @unchecked Sendable {
            func read(_ key: SecretKey) -> String? { nil }
            func write(_ value: String, for key: SecretKey) throws { throw SecretStoreError(status: -1) }
            func delete(_ key: SecretKey) {}
        }
        let defaults = UserDefaults(suiteName: "yuyin-tests-\(UUID())")!
        defaults.set(Data(#"{"mode":"offline","apiKey":"sk-keep"}"#.utf8), forKey: "yuyin.settings")
        _ = SettingsStore(defaults: defaults, secrets: FailingSecrets())
        let persisted = String(data: defaults.data(forKey: "yuyin.settings")!, encoding: .utf8)!
        XCTAssertTrue(persisted.contains("sk-keep"))
    }
}
