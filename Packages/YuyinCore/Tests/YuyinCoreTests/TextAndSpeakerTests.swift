import XCTest
@testable import YuyinCore

final class TextAndSpeakerTests: XCTestCase {
    func testExporterSkipsEmptyAndNumbersSRTSequentially() {
        let a = Utterance(startMs: 1000, endMs: 2500, partial: "测试", finalText: "测试完成。", status: .final, provider: "x")
        let empty = Utterance(startMs: 3000, endMs: 3500, partial: "", finalText: "。", status: .final, provider: "x")
        let b = Utterance(startMs: 3_725_000, endMs: 3_726_000, partial: "第二句", status: .failed, provider: "x", speakerIndex: 1)

        XCTAssertEqual(TranscriptExporter.export([a, empty, b], format: .plainText), "测试完成。\n[说话人 2] 第二句")

        let srt = TranscriptExporter.export([b, empty, a], format: .srt)
        XCTAssertEqual(srt, """
        1
        00:00:01,000 --> 00:00:02,500
        测试完成。

        2
        01:02:05,000 --> 01:02:06,000
        [说话人 2] 第二句

        """)

        let md = TranscriptExporter.export([a, b], format: .markdown, title: "周会")
        XCTAssertTrue(md.hasPrefix("# 周会"))
        XCTAssertTrue(md.contains("- **1:02:05** · *说话人 2* — 第二句"))
    }

    func testHallucinationFilter() {
        XCTAssertTrue(TextFilter.looksHallucinated("我操，这这这这这这这这。"))
        XCTAssertTrue(TextFilter.looksHallucinated("g 零 axy x s x s y s 的这的一西"))
        XCTAssertFalse(TextFilter.looksHallucinated("怎么样才能提高高识别的效果呢？"))
        XCTAssertFalse(TextFilter.looksHallucinated("哈哈哈，好的。"))
        XCTAssertFalse(TextFilter.looksHallucinated("用 Swift 写一个 App"))
        XCTAssertFalse(TextFilter.looksHallucinated("The tribal chieftain called for the boy"))
        // Short Chinese exclamations that a multilingual model turned into Japanese.
        XCTAssertTrue(TextFilter.looksHallucinated("ちょっと。"))
        XCTAssertTrue(TextFilter.looksHallucinated("ええよっ！"))
        XCTAssertTrue(TextFilter.looksHallucinated("최초"))
        XCTAssertFalse(TextFilter.looksHallucinated("这波打过来了。"))
    }

    func testEnglishGetsASCIIPunctuation() {
        XCTAssertEqual(TextFilter.normalizePunctuation("Entrepreneur，and I also do real estate. Well，you're busy。"),
                       "Entrepreneur, and I also do real estate. Well, you're busy.")
        XCTAssertEqual(TextFilter.normalizePunctuation("我们用 Swift，写一个 App。"), "我们用 Swift，写一个 App。")
    }

    func testShortClipsDontCreateSpeakers() {
        var c = OnlineSpeakerClusterer()
        XCTAssertEqual(c.assign([1, 0, 0], speechMs: 500), 0, "the very first clip always starts speaker 1")
        // Noisy short clip of the same person (similarity 0.4) joins instead of splitting.
        XCTAssertEqual(c.assign([0.4, 0.92, 0], speechMs: 400), 0)
        // A short clip unlike anyone (0.3) stays unknown rather than being pinned on speaker 1.
        XCTAssertNil(c.assign([0.3, 0, 0.954], speechMs: 400))
        XCTAssertNil(c.assign([0, 0, 1], speechMs: 300))
        // A confident long clip of someone else starts speaker 2.
        XCTAssertEqual(c.assign([0, 0, 1], speechMs: 2000), 1)
        XCTAssertEqual(c.speakerCount, 2)
    }

    /// The same person's 2 s sentences rarely reach the full threshold; long ones must.
    func testShortClipsJoinAtALowerSimilarity() {
        var c = OnlineSpeakerClusterer()
        XCTAssertEqual(c.joinThreshold(speechMs: 6000), 0.5, accuracy: 0.001)
        XCTAssertEqual(c.joinThreshold(speechMs: 2000), 0.4, accuracy: 0.001)
        XCTAssertEqual(c.assign([1, 0, 0], speechMs: 5000), 0)
        XCTAssertEqual(c.assign([0.45, 0.893, 0], speechMs: 2000), 0, "2 s clip at 0.45 joins")
        var d = OnlineSpeakerClusterer()
        _ = d.assign([1, 0, 0], speechMs: 5000)
        XCTAssertEqual(d.assign([0.45, 0.893, 0], speechMs: 5000), 1, "5 s clip at 0.45 is someone else")
    }

    func testNormalizationRaisesQuietSpeechWithoutClipping() {
        let quiet = Signal.speech(ms: 1000, amplitude: 0.02)
        let loud = AudioSpec.normalizedForRecognition(quiet)
        XCTAssertGreaterThan(AudioSpec.peak(loud), AudioSpec.peak(quiet) * 3)
        XCTAssertLessThanOrEqual(AudioSpec.peak(loud), 0.95 + 1e-4)
        let normal = Signal.speech(ms: 1000, amplitude: 0.3)
        XCTAssertEqual(AudioSpec.normalizedForRecognition(normal), normal, "already loud speech is left alone")
    }

    func testCaseNormalizationAndContentUnits() {
        XCTAssertEqual(TextFilter.normalizeCase("YOUR JOB OH MY GOD I GROWING IT"), "Your job oh my god I growing it")
        XCTAssertEqual(TextFilter.normalizeCase("THIS ENTIRE MEETING. TELL US YOUR NAME"), "This entire meeting. Tell us your name")
        XCTAssertEqual(TextFilter.normalizeCase("苹果全新的 HomePod 呀"), "苹果全新的 HomePod 呀")
        XCTAssertEqual(TextFilter.normalizeCase("我们用 API"), "我们用 API", "short acronyms stay")
        XCTAssertEqual(TextFilter.contentUnits("哎，没布为什么要 iPhone 15"), 9)
    }

    func testTextFilter() {
        XCTAssertFalse(TextFilter.isMeaningful(""))
        XCTAssertFalse(TextFilter.isMeaningful("。，！ "))
        XCTAssertTrue(TextFilter.isMeaningful("好。"))
        XCTAssertTrue(TextFilter.isMeaningful("ok"))
    }

    func testClustererSeparatesSpeakersAndRespectsCap() {
        var c = OnlineSpeakerClusterer(threshold: 0.6)
        XCTAssertEqual(c.assign([1, 0, 0]), 0)
        XCTAssertEqual(c.assign([0.9, 0.1, 0]), 0)
        XCTAssertEqual(c.assign([0, 1, 0]), 1)
        XCTAssertEqual(c.assign([0, 0, 1]), 2)
        XCTAssertNil(c.assign([0, 0, 0]))

        var capped = OnlineSpeakerClusterer(threshold: 0.9, maxSpeakers: 2)
        _ = capped.assign([1, 0])
        _ = capped.assign([0, 1])
        XCTAssertEqual(capped.assign([0.6, 0.8]), 1)
        XCTAssertEqual(capped.speakerCount, 2)
    }

    func testSpeakerMappingRenumbersByFirstAppearance() {
        let u1 = Utterance(startMs: 0, endMs: 1000, provider: "x")
        let u2 = Utterance(startMs: 1200, endMs: 2000, provider: "x")
        let u3 = Utterance(startMs: 9000, endMs: 9500, provider: "x")
        let segments = [
            SpeakerSegment(startMs: 0, endMs: 1100, speakerIndex: 3),
            SpeakerSegment(startMs: 1100, endMs: 2100, speakerIndex: 0),
        ]
        let map = SpeakerMapping.map([u3, u2, u1], segments: segments)
        XCTAssertEqual(map[u1.id], .some(0))
        XCTAssertEqual(map[u2.id], .some(1))
        XCTAssertEqual(map[u3.id], .some(nil))
    }
}
