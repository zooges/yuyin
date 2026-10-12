import AVFoundation
import XCTest
import YuyinCore
@testable import YuyinLocal

/// Runs the real engines against models already installed on this machine
/// (skipped otherwise). Uses the sample WAVs shipped inside the official archives.
final class InstalledModelTests: XCTestCase {
    private let locator = ModelLocator.standard

    private func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, Double(AudioSpec.sampleRate))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private var senseVoiceSample: URL {
        locator.directory(for: .senseVoice).appendingPathComponent("test_wavs/zh.wav")
    }

    func testSherpaSenseVoiceCorrector() async throws {
        try XCTSkipUnless(locator.isInstalled(.senseVoice), "SenseVoice (sherpa) not installed")
        let samples = try load(senseVoiceSample)
        let engine = SherpaOfflineCorrector(kind: .senseVoice, files: try locator.offlineFiles(.senseVoice))
        try await engine.prepare()
        let text = try await engine.correct(samples, hint: "")
        await engine.shutdown()
        print("sherpa-sensevoice:", text)
        XCTAssertTrue(TextFilter.isMeaningful(text))
        XCTAssertTrue(text.contains("时间早上9点至下午5点"), text)
    }

    func testANESenseVoiceProducesPunctuatedChinese() async throws {
        try XCTSkipUnless(locator.isInstalled(.senseVoiceANE), "SenseVoice ANE not installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: senseVoiceSample.path), "sample wav missing")
        let samples = try load(senseVoiceSample)
        let engine = FluidSenseVoiceCorrector(directory: locator.directory(for: .senseVoiceANE))
        try await engine.prepare()
        let text = try await engine.correct(samples, hint: "")
        await engine.shutdown()
        print("ane-sensevoice:", text)
        XCTAssertTrue(text.contains("时间早上9点至下午5点"), text)
        XCTAssertTrue(text.contains("。") || text.contains("，"), "ITN/punctuation enabled: \(text)")
    }

    func testSherpaStreamingThroughSession() async throws {
        try XCTSkipUnless(locator.isInstalled(.streamingXASRFast), "streaming model not installed")
        let wav = locator.directory(for: .streamingXASRFast).appendingPathComponent("test_wavs/0.wav")
        let speech = try load(wav)
        let engines = LocalEngines(locator: locator)
        let streaming = try engines.makeStreaming(.xasrFast)
        let session = TranscriptionSession(
            provider: Fixed(set: EngineSet(streaming: streaming, corrector: nil)),
            settings: AppSettings()
        )
        try await session.start()
        let audio = [Float](repeating: 0, count: 8000) + speech + [Float](repeating: 0, count: 24_000)
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let result = await session.stop()
        print("sherpa-streaming:", result.map(\.displayText))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0.status == .final })
    }

    /// The whole offline 2-pass path: X-ASR partials → VAD sentence → SenseVoice final.
    func testOfflineTwoPassEndToEnd() async throws {
        try XCTSkipUnless(locator.isInstalled(.streamingXASRFast) && locator.isInstalled(.senseVoice), "models not installed")
        let speech = try load(senseVoiceSample)
        let engines = LocalEngines(locator: locator)
        let session = TranscriptionSession(
            provider: Fixed(set: EngineSet(
                streaming: try engines.makeStreaming(.xasrFast),
                corrector: try engines.makeCorrector(.sherpa(.senseVoice))
            )),
            settings: AppSettings()
        )
        let (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let collector = Task { for await e in session.events { continuation.yield(e) }; continuation.finish() }
        try await session.start()
        let audio = [Float](repeating: 0, count: 16_000) + speech + [Float](repeating: 0, count: 24_000)
        for start in stride(from: 0, to: audio.count, by: 1024) {
            await session.ingest(Array(audio[start..<min(start + 1024, audio.count)]))
        }
        let result = await session.stop()
        await collector.value
        var sawPartial = false
        for await e in events {
            if case .upsert(let u) = e, u.status == .partial, !u.partial.isEmpty { sawPartial = true }
        }
        print("two-pass:", result.map { "\($0.startMs)-\($0.endMs ?? 0) [\($0.provider)] \($0.displayText)" })
        XCTAssertTrue(sawPartial, "streaming partials were shown before the final")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.status, .final)
        XCTAssertEqual(result.first?.provider, "sherpa-sensevoice")
        XCTAssertTrue(result.first?.displayText.contains("时间早上9点至下午5点") == true)
        // 1 s of padding + zh.wav's own ~0.7 s of leading silence.
        XCTAssertEqual(Double(result.first?.startMs ?? 0), 1700, accuracy: 150)
    }

    private struct Fixed: EngineProvider {
        let set: EngineSet
        func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
    }
}
