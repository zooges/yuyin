import XCTest
@testable import YuyinCore

final class SessionTests: XCTestCase {
    // Short sentences need a 1.3 s pause to close (`shortSentenceSilenceMs`).
    private let twoSentences = Signal.silence(ms: 1000) + Signal.tone(ms: 1200) + Signal.silence(ms: 1500)
        + Signal.tone(ms: 800) + Signal.silence(ms: 1500)

    private func makeSession(
        streaming: ScriptedStreaming = ScriptedStreaming(),
        corrector: ScriptedCorrector? = ScriptedCorrector(),
        fallback: ScriptedCorrector? = nil,
        settings: AppSettings = AppSettings()
    ) -> TranscriptionSession {
        TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: streaming, corrector: corrector, fallbackCorrector: fallback)),
            settings: settings
        )
    }

    func testTwoSentencesAreCorrectedInOrderWithAudioTimestamps() async throws {
        let session = makeSession()
        try await session.start()
        await session.feed(twoSentences)
        let result = await session.stop()

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.status == .final })
        XCTAssertTrue(result.allSatisfy { $0.finalText?.hasPrefix("纠字") == true })
        XCTAssertEqual(result.map(\.provider), ["test-correct", "test-correct"])
        XCTAssertEqual(Double(result[0].startMs), 1000, accuracy: 30)
        XCTAssertEqual(Double(result[0].endMs ?? 0), 2200, accuracy: 30)
        XCTAssertEqual(Double(result[1].startMs), 3700, accuracy: 30)
        let elapsed = await session.elapsedMs
        XCTAssertEqual(Double(elapsed), 6000, accuracy: 70)
    }

    func testEventsAreNotLostBeforeSubscribing() async throws {
        let session = makeSession()
        try await session.start()
        let (log, task) = EventLog.collect(session)
        await session.stop()
        await task.value
        let phases = await log.phases
        XCTAssertEqual(phases, [.preparing, .listening, .finishing, .idle])
    }

    func testStopWaitsForQueuedCorrectionsAndRunsThemSerially() async throws {
        let corrector = ScriptedCorrector()
        corrector.delayNanos = 80_000_000
        let session = makeSession(corrector: corrector)
        try await session.start()
        await session.feed(twoSentences)
        // Second sentence is still open-ish / queued; stop must drain everything.
        let result = await session.stop()
        XCTAssertEqual(result.map(\.status), [.final, .final])
        XCTAssertEqual(corrector.calls, 2)
        XCTAssertEqual(corrector.maxConcurrent, 1)
    }

    func testStopFlushesOpenSentence() async throws {
        let session = makeSession()
        try await session.start()
        await session.feed(Signal.silence(ms: 500) + Signal.tone(ms: 1000))
        let result = await session.stop()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.status, .final)
    }

    func testHybridFallsBackToLocalCorrector() async throws {
        let cloud = ScriptedCorrector(id: "cloud")
        cloud.error = ASRError.network("offline")
        let local = ScriptedCorrector(id: "local")
        let session = makeSession(corrector: cloud, fallback: local, settings: AppSettings(mode: .hybrid))
        let (log, task) = EventLog.collect(session)
        try await session.start()
        await session.feed(twoSentences)
        let result = await session.stop()
        await task.value

        XCTAssertEqual(result.map(\.provider), ["local", "local"])
        XCTAssertTrue(result.allSatisfy { $0.status == .final })
        let notices = await log.notices
        XCTAssertEqual(notices.count, 1, "fallback notice is shown once, not per sentence")
    }

    func testFailedCorrectionKeepsStreamingText() async throws {
        let corrector = ScriptedCorrector()
        corrector.error = ASRError.inferenceFailed("boom")
        let session = makeSession(corrector: corrector)
        try await session.start()
        await session.feed(Signal.silence(ms: 300) + Signal.tone(ms: 600) + Signal.silence(ms: 1000))
        let result = await session.stop()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, .failed)
        XCTAssertEqual(result[0].displayText.isEmpty, false)
        XCTAssertNotNil(result[0].errorMessage)
    }

    func testWithoutCorrectorStreamingTextBecomesFinal() async throws {
        let session = makeSession(corrector: nil)
        try await session.start()
        await session.feed(twoSentences)
        let result = await session.stop()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.provider), ["test-stream", "test-stream"])
        XCTAssertTrue(result.allSatisfy { $0.status == .final && $0.finalText?.hasPrefix("字") == true })
    }

    func testPunctuationOnlyResultIsRemoved() async throws {
        let corrector = ScriptedCorrector()
        corrector.output = { _ in "。" }
        let session = makeSession(corrector: corrector)
        let (log, task) = EventLog.collect(session)
        try await session.start()
        await session.feed(Signal.silence(ms: 300) + Signal.tone(ms: 600) + Signal.silence(ms: 1000))
        let result = await session.stop()
        await task.value
        XCTAssertTrue(result.isEmpty)
        let removals = await log.removals
        XCTAssertEqual(removals, 1)
    }

    func testNoiseBlipWithoutTextCreatesNothing() async throws {
        let corrector = ScriptedCorrector()
        let session = makeSession(corrector: corrector)
        try await session.start()
        await session.feed(Signal.silence(ms: 500) + Signal.tone(ms: 60, amplitude: 0.02) + Signal.silence(ms: 2000))
        let result = await session.stop()
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(corrector.calls, 0)
    }

    /// Regression: a recognizer endpoint in mid-speech (a drawn-out syllable, game sounds) split
    /// "他应该学的是 / E技能" into two sentences, and the fragment was recognized as Japanese.
    func testEngineEndpointWithoutAPauseKeepsTheSentenceOpen() async throws {
        let streaming = ScriptedStreaming()
        streaming.endpointAfterChars = 5
        let session = makeSession(streaming: streaming)
        try await session.start()
        await session.feed(Signal.silence(ms: 200) + Signal.tone(ms: 700))
        let mid = await session.utterances
        XCTAssertEqual(mid.count, 1)
        XCTAssertEqual(mid.first?.status, .partial)
        await session.feed(Signal.silence(ms: 1500))
        let result = await session.stop()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.partial.count, 12, "one sentence with all the text")
    }

    /// Continuous program audio, where the VAD never hears a pause, is still split by endpoints.
    func testEngineEndpointClosesALongSentenceWithoutAPause() async throws {
        let streaming = ScriptedStreaming()
        streaming.endpointAfterChars = 20
        var segmentation = SegmenterConfig()
        segmentation.endpointBackstopMs = 1_000
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: streaming, corrector: ScriptedCorrector())),
            settings: AppSettings(), segmentation: segmentation
        )
        try await session.start()
        await session.feed(Signal.silence(ms: 200) + Signal.tone(ms: 1800))
        let mid = await session.utterances
        XCTAssertEqual(mid.count, 2, "closed sentence + the one still being spoken")
        XCTAssertNotEqual(mid.first?.status, .partial)
        XCTAssertEqual(mid.last?.status, .partial)
        await session.stop()
    }

    func testPauseClosesSentenceAndDropsAudioWhilePaused() async throws {
        let session = makeSession()
        try await session.start()
        await session.feed(Signal.silence(ms: 200) + Signal.tone(ms: 800))
        await session.pause()
        await session.feed(Signal.tone(ms: 2000))
        let pausedElapsed = await session.elapsedMs
        await session.resume()
        let result = await session.stop()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Double(pausedElapsed), 1000, accuracy: 70)
    }

    func testStartFailureFinishesEvents() async {
        let streaming = ScriptedStreaming()
        streaming.prepareError = ASRError.modelMissing("x")
        let session = makeSession(streaming: streaming)
        let (log, task) = EventLog.collect(session)
        do {
            try await session.start()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ASRError, .modelMissing("x"))
        }
        await task.value
        let phases = await log.phases
        XCTAssertEqual(phases, [.preparing, .idle])
        XCTAssertEqual(streaming.shutdownCount, 1)
    }

    func testAudioSinkReceivesExactlyIngestedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yuyin-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try WAVFileWriter(url: url)
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: ScriptedStreaming(), corrector: nil)),
            settings: AppSettings(),
            audioSink: sink
        )
        try await session.start()
        await session.feed(twoSentences)
        await session.stop()
        let read = try WAVFile.read(url)
        XCTAssertEqual(read.count, twoSentences.count)
    }

    func testConcurrentStopsBothWaitForTheDrain() async throws {
        let corrector = ScriptedCorrector()
        corrector.delayNanos = 60_000_000
        let session = makeSession(corrector: corrector)
        try await session.start()
        await session.feed(twoSentences)
        async let first = session.stop()
        async let second = session.stop()
        let (a, b) = await (first, second)
        XCTAssertEqual(a.map(\.status), [.final, .final])
        XCTAssertEqual(b.map(\.status), [.final, .final], "second stop must not return before corrections finish")
    }

    /// Regression: sherpa's delayed silence endpoint fired just after a new sentence began
    /// and chopped it into a 300 ms fragment.
    func testEmptyEndpointNeverChopsAStartingSentence() async throws {
        let streaming = ScriptedStreaming()
        streaming.silenceEndpoints = true
        streaming.textDelayChunks = 4
        let corrector = ScriptedCorrector()
        let session = makeSession(streaming: streaming, corrector: corrector)
        try await session.start()
        await session.feed(Signal.silence(ms: 3000) + Signal.tone(ms: 1500) + Signal.silence(ms: 1000))
        let result = await session.stop()
        XCTAssertEqual(result.count, 1)
        let sentence = try XCTUnwrap(result.first)
        XCTAssertEqual(Double(sentence.startMs), 3000, accuracy: 40)
        XCTAssertEqual(Double(sentence.endMs ?? 0), 4500, accuracy: 40)
        XCTAssertEqual(corrector.calls, 1)
    }

    /// Two people talking back to back without a pause: the sentence is cut where the second
    /// voice takes over, and each part gets its own speaker.
    func testSpeakerChangeWithoutAPauseSplitsTheSentence() async throws {
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(
                streaming: ScriptedStreaming(), corrector: ScriptedCorrector(),
                speakerLabeler: PitchSpeakerLabeler(), voiceDetector: LevelVoiceDetector()
            )),
            settings: AppSettings()
        )
        try await session.start()
        await session.feed(Signal.silence(ms: 500) + Signal.tone(ms: 4_000) + Signal.tone(ms: 4_000, frequency: 440)
                           + Signal.silence(ms: 1_500), chunk: 1600)
        let result = await session.stop()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.speakerIndex), [0, 1])
        XCTAssertEqual(Double(result[0].endMs ?? 0), 4_500, accuracy: 400)
        XCTAssertEqual(Double(result[1].startMs), 4_500, accuracy: 400)
        XCTAssertTrue(result.allSatisfy { !$0.partial.isEmpty }, "the second part's live text comes from the audio fed again")
    }

    /// Recording starts before the models are ready: speech from that time is still recognized.
    func testAudioIngestedWhileEnginesLoadIsKept() async throws {
        let streaming = ScriptedStreaming()
        streaming.prepareDelayNanos = 300_000_000
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: streaming, corrector: ScriptedCorrector())),
            settings: AppSettings()
        )
        let starting = Task { try await session.start() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .preparing)
        await session.feed(Signal.silence(ms: 500) + Signal.speech(ms: 1_500))
        try await starting.value
        await session.feed(Signal.silence(ms: 1_500))
        let result = await session.stop()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Double(result.first?.startMs ?? 0), 500, accuracy: 60)
        XCTAssertEqual(Double(result.first?.endMs ?? 0), 2_000, accuracy: 60)
    }

    /// Fluent speech without a pause reaching the length limit: the cut goes at the recognizer's
    /// latest comma, not at any quiet frame of the last seconds.
    func testLengthCutGoesNearTheLatestClauseMark() async throws {
        let streaming = ScriptedStreaming()
        streaming.clauseEveryChars = 30 // a comma every 3 s of speech (1600-sample chunks)
        var settings = AppSettings()
        settings.maxUtteranceSeconds = 10
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: streaming, corrector: ScriptedCorrector(),
                                                    voiceDetector: LevelVoiceDetector())),
            settings: settings, earlyCorrections: false
        )
        try await session.start()
        await session.feed(Signal.silence(ms: 500) + Signal.speech(ms: 14_000) + Signal.silence(ms: 1_500), chunk: 1600)
        let result = await session.stop()
        XCTAssertEqual(result.count, 2)
        // Commas at 3.5, 6.5 and 9.5 s; the 10 s limit cuts near the last one.
        XCTAssertEqual(Double(result[0].endMs ?? 0), 9_500, accuracy: 250)
        XCTAssertEqual(Double(result[1].startMs), 9_500, accuracy: 250)
        // Its live text stops at the comma (one character of slack for recognizer lag).
        let afterComma = result[0].partial.split(separator: "，", omittingEmptySubsequences: false).last ?? ""
        XCTAssertEqual(result[0].partial.filter { $0 == "，" }.count, 3, result[0].partial)
        XCTAssertLessThanOrEqual(afterComma.count, 1, result[0].partial)
        XCTAssertFalse(result[1].partial.isEmpty)
    }

    /// A long sentence still being spoken shows corrected text early: the corrector's version
    /// of what was said so far, followed by the live text heard since.
    func testLongSentenceShowsAnEarlyCorrectionBeforeItEnds() async throws {
        let corrector = ScriptedCorrector()
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: ScriptedStreaming(), corrector: corrector,
                                                    voiceDetector: LevelVoiceDetector())),
            settings: AppSettings()
        )
        let (log, collecting) = EventLog.collect(session)
        try await session.start()
        await session.feed(Signal.silence(ms: 500) + Signal.speech(ms: 9_000), chunk: 1600)
        // The early correction runs beside the audio; give it a moment.
        try await Task.sleep(nanoseconds: 200_000_000)
        await session.feed(Signal.speech(ms: 1_000), chunk: 1600)
        let early = await log.events.compactMap { event -> Utterance? in
            if case .upsert(let u) = event, u.status == .partial, u.partial.hasPrefix("纠") { return u }
            return nil
        }
        XCTAssertFalse(early.isEmpty, "an early correction was shown while the sentence was open")
        // It is followed by the live text heard after it.
        XCTAssertTrue(early.last.map { $0.partial.hasSuffix("字") } ?? false, early.last?.partial ?? "")
        await session.feed(Signal.silence(ms: 1_500), chunk: 1600)
        let result = await session.stop()
        collecting.cancel()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.status, .final)
    }

    /// Narration without pauses (videos through system audio): past 6 s the sentence closes at
    /// the recognizer's full stop, a little before it (the mark comes as the next word starts).
    func testLongSentenceWithoutAPauseClosesAtAFullStop() async throws {
        let streaming = ScriptedStreaming()
        streaming.clauseEveryChars = 30
        streaming.clauseMark = "。"
        let session = TranscriptionSession(
            provider: StaticProvider(set: EngineSet(streaming: streaming, corrector: ScriptedCorrector(),
                                                    voiceDetector: LevelVoiceDetector())),
            settings: AppSettings(), earlyCorrections: false
        )
        try await session.start()
        await session.feed(Signal.silence(ms: 500) + Signal.speech(ms: 12_000) + Signal.silence(ms: 1_500), chunk: 1600)
        let result = await session.stop()
        XCTAssertGreaterThanOrEqual(result.count, 2)
        // Full stops at 3.5, 6.5, 9.5 s; once past 6 s, the cut goes ~0.25 s before the 3.5 s one.
        XCTAssertEqual(Double(result[0].endMs ?? 0), 3_250, accuracy: 300)
        XCTAssertTrue(result.allSatisfy { ($0.endMs ?? 0) - $0.startMs < 10_000 })
    }
}

