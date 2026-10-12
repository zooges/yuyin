import XCTest
@testable import YuyinCore

final class SegmenterTests: XCTestCase {
    private func run(_ samples: [Float], chunk: Int, config: SegmenterConfig = SegmenterConfig()) -> ([Segment], UtteranceSegmenter) {
        var seg = UtteranceSegmenter(config: config)
        var out: [Segment] = []
        for c in Signal.chunks(samples, size: chunk) {
            out += seg.push(c)
        }
        return (out, seg)
    }

    func testSpeechThenSilenceProducesOneTrimmedSegment() {
        let audio = Signal.silence(ms: 1000) + Signal.tone(ms: 1500) + Signal.silence(ms: 1500)
        let (segments, _) = run(audio, chunk: 1024)
        XCTAssertEqual(segments.count, 1)
        let s = try! XCTUnwrap(segments.first)
        XCTAssertEqual(s.reason, .silence)
        // Voice onset at 1000 ms, within one frame.
        XCTAssertEqual(AudioSpec.milliseconds(forSamples: s.speechStartSample), 1000, accuracy: 20)
        XCTAssertEqual(AudioSpec.milliseconds(forSamples: s.speechEndSample), 2500, accuracy: 20)
        // Contiguous: starts where the audio started; ends 200 ms after the last voiced frame.
        XCTAssertEqual(s.startSample, 0)
        XCTAssertEqual(AudioSpec.milliseconds(forSamples: s.endSample), 2700, accuracy: 20)
        XCTAssertEqual(s.samples.count, s.endSample - s.startSample)
        XCTAssertEqual(s.speechMs, 1500, accuracy: 20)
    }

    func testResultIsIndependentOfChunkSize() {
        let audio = Signal.silence(ms: 500) + Signal.tone(ms: 800) + Signal.silence(ms: 1500)
            + Signal.tone(ms: 1200) + Signal.silence(ms: 1500)
        let (a, _) = run(audio, chunk: 160)
        let (b, _) = run(audio, chunk: 4096)
        let (c, _) = run(audio, chunk: 333)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    /// A short sentence followed by a natural pause is usually unfinished ("先来把一刀……斩"):
    /// it stays open for the rest, while a longer sentence still closes after the normal pause.
    func testShortSentenceNeedsALongerPause() {
        let short = Signal.silence(ms: 500) + Signal.tone(ms: 900) + Signal.silence(ms: 1000)
            + Signal.tone(ms: 900) + Signal.silence(ms: 1500)
        XCTAssertEqual(run(short, chunk: 512).0.count, 1)

        let long = Signal.silence(ms: 500) + Signal.tone(ms: 2500) + Signal.silence(ms: 1000)
            + Signal.tone(ms: 900) + Signal.silence(ms: 1500)
        XCTAssertEqual(run(long, chunk: 512).0.count, 2)
    }

    func testShortClickIsIgnored() {
        let audio = Signal.silence(ms: 500) + Signal.tone(ms: 100) + Signal.silence(ms: 1500)
        let (segments, seg) = run(audio, chunk: 512)
        XCTAssertTrue(segments.isEmpty)
        XCTAssertFalse(seg.hasSpeech)
    }

    func testMaxLengthCutsContiguously() {
        var config = SegmenterConfig()
        config.maxUtteranceMs = 2000
        config.shortSentenceMs = 0 // with 2 s pieces every piece would count as short
        let audio = Signal.silence(ms: 300) + Signal.speech(ms: 5000) + Signal.silence(ms: 1000)
        let (segments, _) = run(audio, chunk: 1024, config: config)
        XCTAssertGreaterThanOrEqual(segments.count, 3)
        XCTAssertTrue(segments.dropLast().allSatisfy { $0.reason == .maxLength })
        XCTAssertEqual(segments.last?.reason, .silence)
        for (prev, next) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(prev.endSample, next.startSample, "no gap or overlap between cut pieces")
        }
        XCTAssertTrue(segments.allSatisfy {
            $0.samples.count <= AudioSpec.samples(forMilliseconds: 2000) && $0.samples.count >= AudioSpec.samples(forMilliseconds: 1000)
        }, "soft cuts land in the second half of the allowed length")
    }

    func testIdleAudioIsKeptUntilDiscardedAndForcedCutReturnsIt() {
        let (segments, seg0) = run(Signal.silence(ms: 12_000), chunk: 1024)
        var seg = seg0
        XCTAssertTrue(segments.isEmpty)
        seg.discardIdle(keepingMs: 2_000)
        let forced = try! XCTUnwrap(seg.cut())
        XCTAssertEqual(forced.reason, .forced)
        XCTAssertEqual(forced.speechMs, 0)
        XCTAssertEqual(forced.samples.count, AudioSpec.samples(forMilliseconds: 2_000))
    }

    /// Regression: continuous program audio (speech over music) that the VAD can't split
    /// must still reach the corrector in full — no audio between cuts may be dropped.
    func testContinuousAudioIsNeverDropped() {
        var config = SegmenterConfig()
        config.maxUtteranceMs = 4_000
        // Music bed + speech, never silent.
        let bed = Signal.silence(ms: 20_000, noise: 0.05)
        let speech = Signal.speech(ms: 20_000, amplitude: 0.08)
        let audio = zip(bed, speech).map { $0 + $1 }
        var seg = UtteranceSegmenter(config: config)
        var segments: [Segment] = []
        for c in Signal.chunks(audio, size: 1600) { segments += seg.push(c) }
        if let tail = seg.cut() { segments.append(tail) }
        XCTAssertEqual(segments.first?.startSample, 0)
        XCTAssertEqual(segments.last?.endSample, audio.count)
        for (prev, next) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(prev.endSample, next.startSample)
        }
        XCTAssertEqual(segments.reduce(0) { $0 + $1.samples.count }, audio.count, "every sample is in exactly one segment")
    }

    func testSteadyNoiseStopsCountingAsSpeech() {
        // Fan noise well above the absolute threshold.
        let noise = Signal.silence(ms: 6000, noise: 0.03)
        let speech = Signal.speech(ms: 1200, amplitude: 0.3)
        var seg = UtteranceSegmenter()
        var early: [Segment] = []
        for c in Signal.chunks(noise, size: 1024) { early += seg.push(c) }
        XCTAssertFalse(seg.hasSpeech, "noise floor adapted within the noise-only lead-in")
        var later: [Segment] = []
        for c in Signal.chunks(speech + noise, size: 1024) { later += seg.push(c) }
        XCTAssertEqual(later.count, 1)
        let span = (later.first?.speechEndSample ?? 0) - (later.first?.speechStartSample ?? 0)
        XCTAssertEqual(Double(AudioSpec.milliseconds(forSamples: span)), 1200, accuracy: 100)
    }

    /// Quiet speech (−38 dBFS) with noise spikes inside the pauses, like a laptop mic.
    func testQuietSpeechWithSpikyPausesIsStillSplit() {
        func pause(ms: Int) -> [Float] {
            var p = Signal.silence(ms: ms, noise: 0.006)
            // A 20 ms click every 300 ms.
            for start in stride(from: 0, to: p.count - 320, by: 4800) {
                for i in start..<(start + 320) { p[i] = sin(Float(i)) * 0.03 }
            }
            return p
        }
        let audio = Signal.silence(ms: 200, noise: 0.0002) + Signal.tone(ms: 300, amplitude: 0.5) // click at start
            + pause(ms: 2000) + Signal.speech(ms: 1500, amplitude: 0.025) + pause(ms: 1500)
            + Signal.speech(ms: 900, amplitude: 0.025) + pause(ms: 1500)
        let (segments, _) = run(audio, chunk: 1024)
        let starts = segments.map { AudioSpec.milliseconds(forSamples: $0.speechStartSample) }
        XCTAssertTrue(segments.allSatisfy { $0.reason == .silence })
        // Both sentences start their own segment (the click before them may form a third).
        XCTAssertTrue(starts.contains { abs($0 - 2500) <= 120 }, "\(starts)")
        XCTAssertTrue(starts.contains { abs($0 - 5500) <= 120 }, "\(starts)")
    }
}
