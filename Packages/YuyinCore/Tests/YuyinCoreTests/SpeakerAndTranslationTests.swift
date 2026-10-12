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

    func testSpeakersAreListedByFirstAppearanceInTime() {
        // Not in time order, with a tie: the earliest start wins, ties keep array order.
        let tieA = Utterance(startMs: 1_000, provider: "x", speakerIndex: 1)
        let tieB = Utterance(startMs: 1_000, provider: "x", speakerIndex: 0)
        let again = Utterance(startMs: 2_000, provider: "x", speakerIndex: 2)
        let unknown = Utterance(startMs: 0, provider: "x")
        let early = Utterance(startMs: 500, provider: "x", speakerIndex: 2)
        XCTAssertEqual(SpeakerBook().speakers(in: [tieA, tieB, again, unknown, early]), [2, 1, 0])
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

    func testSpeakerChangeNeedsTwoDissimilarWindowsAndAMinimumPiece() {
        var detector = SpeakerChangeDetector()
        detector.start(at: 0)
        let hop = AudioSpec.samples(forMilliseconds: 500)
        let a: [Float] = [1, 0], b: [Float] = [0, 1]
        // Speaker A for 4 windows, one stray B window, then B for good.
        let sequence = [a, a, a, a, b, a, b, b, b]
        var changes: [Int] = []
        for (i, e) in sequence.enumerated() {
            if let change = detector.observe(e, windowStart: i * hop) { changes.append(change) }
        }
        // The first of the two B windows in a row starts at 6 hops; the change is mid-window.
        XCTAssertEqual(changes, [6 * hop + AudioSpec.samples(forMilliseconds: 750)])

        var early = SpeakerChangeDetector()
        early.start(at: 0)
        XCTAssertNil(early.observe(a, windowStart: 0))
        XCTAssertNil(early.observe(b, windowStart: 0))
        XCTAssertNil(early.observe(b, windowStart: 0), "a change 0.75 s in leaves too short a first piece")
    }
}
