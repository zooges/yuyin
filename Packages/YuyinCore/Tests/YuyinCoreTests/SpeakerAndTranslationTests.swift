import XCTest
@testable import YuyinCore

final class ScriptedTranslator: TextTranslator, @unchecked Sendable {
    let providerID = "test-translate"
    var error: Error?
    var delayNanos: UInt64 = 0
    private let lock = NSLock()
    private(set) var requests: [(String, Language, Language)] = []

    func prepare() async throws {}

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        lock.withLock { requests.append((text, source, target)) }
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        if let error { throw error }
        return "EN(\(text))"
    }

    func shutdown() async {}
}

final class SpeakerAndTranslationTests: XCTestCase {
    func testSpeakerBookNamesMergesAndReassigns() {
        let a = Utterance(startMs: 0, partial: "a", status: .final, provider: "x", speakerIndex: 0)
        let b = Utterance(startMs: 10, partial: "b", status: .final, provider: "x", speakerIndex: 1)
        let c = Utterance(startMs: 20, partial: "c", status: .final, provider: "x", speakerIndex: 2)
        var book = SpeakerBook()
        XCTAssertEqual(book.label(for: 1), "说话人 2")
        XCTAssertNil(book.label(for: nil))

        XCTAssertEqual(book.rename(0, to: " 张三 "), 0)
        XCTAssertEqual(book.label(for: 0), "张三")
        // Same name as speaker 0 → speaker 2 is merged into 0.
        XCTAssertEqual(book.rename(2, to: "张三"), 0)
        XCTAssertEqual(book.resolve(c).speakerIndex, 0)
        XCTAssertEqual(book.speakers(in: [a, b, c]), [0, 1])

        // Sentence b actually belongs to 张三.
        book.reassign(b.id, to: 0)
        XCTAssertEqual(book.resolve(b).speakerIndex, 0)
        XCTAssertEqual(book.nextIndex(after: [a, b, c]), 3)

        book.rename(0, to: "")
        XCTAssertEqual(book.label(for: 2), "说话人 1", "cleared name falls back to the surviving default label")
    }

    func testTransferNamesAfterRediarization() {
        let u1 = Utterance(startMs: 0, provider: "x", speakerIndex: 0)
        let u2 = Utterance(startMs: 1, provider: "x", speakerIndex: 0)
        let u3 = Utterance(startMs: 2, provider: "x", speakerIndex: 1)
        let map: [UUID: Int?] = [u1.id: 1, u2.id: 1, u3.id: 0]
        let names = SpeakerMapping.transferNames([0: "张三", 1: "李四"], from: [u1, u2, u3], to: map)
        XCTAssertEqual(names, [1: "张三", 0: "李四"])
    }

    func testExportUsesNamesAndTranslations() {
        let u = Utterance(startMs: 0, endMs: 1000, partial: "你好", finalText: "你好。", status: .final,
                          provider: "x", speakerIndex: 0, translation: "Hello.")
        XCTAssertEqual(TranscriptExporter.export([u], format: .plainText, speakerNames: [0: "张三"]), "[张三] 你好。\n    Hello.")
        XCTAssertEqual(TranscriptExporter.export([u], format: .plainText, includeTranslation: false), "[说话人 1] 你好。")
        let srt = TranscriptExporter.export([u], format: .srt, speakerNames: [0: "张三"])
        XCTAssertTrue(srt.contains("[张三] 你好。\nHello."))
        let meeting = Meeting(title: "周会", utterances: [u], speakerNames: [0: "张三"])
        XCTAssertTrue(meeting.export(.markdown).contains("*张三* — 你好。\n  > Hello."))
    }

    func testLanguageGuessAndDirection() {
        XCTAssertEqual(Language.guess("今天天气不错"), .zh)
        XCTAssertEqual(Language.guess("Let's start the meeting"), .en)
        XCTAssertEqual(Language.guess("我们用 Swift 写"), .zh)
        XCTAssertEqual(Language.guess("こんにちは、元気ですか"), .ja)
        XCTAssertEqual(Language.guess("안녕하세요"), .ko)
        XCTAssertEqual(TranslationTarget.auto.direction(for: "你好")?.target, .en)
        XCTAssertEqual(TranslationTarget.auto.direction(for: "hello there")?.target, .zh)
        XCTAssertNil(TranslationTarget.en.direction(for: "hello there"))
    }

    func testSessionTranslatesFinalsWithoutDelayingCorrections() async throws {
        let translator = ScriptedTranslator()
        translator.delayNanos = 50_000_000
        var settings = AppSettings()
        settings.translation = TranslationOptions(enabled: true, target: .auto)
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: ScriptedStreaming(), corrector: ScriptedCorrector(), translator: translator)),
            settings: settings
        )
        try await session.start()
        await session.feed(Signal.silence(ms: 300) + Signal.tone(ms: 800) + Signal.silence(ms: 1500)
            + Signal.tone(ms: 800) + Signal.silence(ms: 1500))
        let result = await session.stop()
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.status == .final && $0.translation?.hasPrefix("EN(纠字") == true },
                      "stop() waits for translations too")
        XCTAssertEqual(translator.requests.map(\.2), [.en, .en])
    }

    func testTranslationFailureIsANoticeNotAFailedSentence() async throws {
        let translator = ScriptedTranslator()
        translator.error = ASRError.network("offline")
        var settings = AppSettings()
        settings.translation = TranslationOptions(enabled: true)
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: ScriptedStreaming(), corrector: ScriptedCorrector(), translator: translator)),
            settings: settings
        )
        let (log, task) = EventLog.collect(session)
        try await session.start()
        await session.feed(Signal.silence(ms: 300) + Signal.tone(ms: 800) + Signal.silence(ms: 900))
        let result = await session.stop()
        await task.value
        XCTAssertEqual(result.first?.status, .final)
        XCTAssertNil(result.first?.translation)
        let notices = await log.notices
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].hasPrefix("翻译失败"))
    }
}
