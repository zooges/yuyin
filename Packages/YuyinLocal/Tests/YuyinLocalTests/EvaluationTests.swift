import AVFoundation
import XCTest
import YuyinCore
@testable import YuyinLocal

/// Offline evaluation on real recordings (dev tool, skipped by default).
///
///     YUYIN_EVAL_WAV=<recording audio.wav> [YUYIN_EVAL_MODELS=/tmp/yuyin-eval] \
///         swift test --filter EvaluationTests/testCorrectorComparison
///
/// Candidate models are looked up as extracted official archives under YUYIN_EVAL_MODELS.
final class EvaluationTests: XCTestCase {
    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["YUYIN_EVAL_WAV"] != nil || env["YUYIN_EVAL"] == "1", "evaluation only")
    }

    private var wav: URL? {
        ProcessInfo.processInfo.environment["YUYIN_EVAL_WAV"].map { URL(fileURLWithPath: $0) }
    }

    func testSegmentationTrace() throws {
        let url = try XCTUnwrap(wav, "set YUYIN_EVAL_WAV")
        let audio = try WAVFile.read(url)
        print("audio \(audio.count / 16) ms, peak \(AudioSpec.peak(audio))")
        var profile = ""
        for start in stride(from: 0, to: audio.count, by: 8000) {
            profile += String(format: "%.3f ", AudioSpec.rms(audio[start..<min(start + 8000, audio.count)]))
        }
        print("rms/500ms: \(profile)")
        var seg = UtteranceSegmenter()
        let engine = SherpaStreamingEngine(files: try ModelLocator.standard.streamingFiles())
        let done = expectation(description: "stream")
        Task {
            try await engine.prepare()
            var t = 0
            for start in stride(from: 0, to: audio.count, by: 1600) {
                let chunk = Array(audio[start..<min(start + 1600, audio.count)])
                for s in seg.push(chunk) {
                    print(String(format: "VAD %@ %.2f-%.2f voiced=%d", "\(s.reason)", Double(s.speechStartSample) / 16000, Double(s.speechEndSample) / 16000, s.speechMs))
                }
                let u = try await engine.accept(chunk)
                t += chunk.count
                if u.isEndpoint {
                    print(String(format: "ENGINE endpoint at %.2f text=%@ vadSpeech=%@", Double(t) / 16000, u.text, "\(seg.hasSpeech)"))
                    _ = await engine.finishUtterance()
                }
            }
            if let s = seg.cut() {
                print(String(format: "VAD end-of-file %@ %.2f-%.2f voiced=%d", "\(s.reason)", Double(s.speechStartSample) / 16000, Double(s.speechEndSample) / 16000, s.speechMs))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
    }
}

import SherpaOnnx

extension EvaluationTests {
    static let evalRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YUYIN_EVAL_MODELS"] ?? "/tmp/yuyin-eval")

    static func dir(_ prefix: String) -> URL? {
        let fm = FileManager.default
        guard let tops = try? fm.contentsOfDirectory(at: evalRoot, includingPropertiesForKeys: nil) else { return nil }
        for top in tops {
            if let inner = try? fm.contentsOfDirectory(at: top, includingPropertiesForKeys: nil),
               let hit = inner.first(where: { $0.lastPathComponent.hasPrefix(prefix) && $0.hasDirectoryPath }) {
                return hit
            }
        }
        return nil
    }

    /// Speech segments from Silero VAD (sherpa's own segmentation).
    static func sileroSegments(_ audio: [Float]) -> [(start: Int, samples: [Float])] {
        let model = evalRoot.appendingPathComponent("dl-vad/silero_vad.onnx").path
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(model: model, threshold: 0.5, minSilenceDuration: 0.5, minSpeechDuration: 0.25, maxSpeechDuration: 20)
        )
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 60)
        var out: [(Int, [Float])] = []
        for start in stride(from: 0, to: audio.count, by: 512) {
            vad.acceptWaveform(samples: Array(audio[start..<min(start + 512, audio.count)]))
            while !vad.isEmpty() {
                let s = vad.front()
                out.append((s.start, s.samples))
                vad.pop()
            }
        }
        vad.flush()
        while !vad.isEmpty() {
            let s = vad.front()
            out.append((s.start, s.samples))
            vad.pop()
        }
        return out
    }

    static func normalize(_ s: [Float], targetRMS: Float = 0.08, maxGain: Float = 12) -> [Float] {
        // Speech level from the loudest 30% of 20 ms frames, so pauses don't inflate the gain.
        var levels: [Float] = []
        for start in stride(from: 0, to: s.count, by: 320) {
            levels.append(AudioSpec.rms(s[start..<min(start + 320, s.count)]))
        }
        levels.sort()
        let speech = levels.isEmpty ? 0 : levels[Int(Double(levels.count) * 0.7)..<levels.count].reduce(0, +) / Float(levels.count - Int(Double(levels.count) * 0.7))
        guard speech > 0 else { return s }
        let peak = AudioSpec.peak(s)
        let gain = min(maxGain, targetRMS / speech, peak > 0 ? 0.95 / peak : maxGain)
        return gain > 1 ? s.map { $0 * gain } : s
    }

    func testStreamingAndVADComparison() async throws {
        let url = try XCTUnwrap(wav, "set YUYIN_EVAL_WAV")
        let audio = try WAVFile.read(url)
        let segments = Self.sileroSegments(audio)
        print("SILERO segments:", segments.map { String(format: "%.2f-%.2f", Double($0.start) / 16000, Double($0.start + $0.samples.count) / 16000) }.joined(separator: " "))

        var models: [(String, ModelLocator, URL?)] = [("bilingual-2023", .standard, nil)]
        if let zh = Self.dir("sherpa-onnx-streaming-zipformer-zh-int8") { models.append(("zh-2025", .standard, zh)) }
        for (name, locator, dir) in models {
            for (label, input) in [("raw", audio), ("norm", Self.normalize(audio))] {
                let engine = SherpaStreamingEngine(files: try locator.streamingFiles(in: dir))
                try await engine.prepare()
                var texts: [String] = []
                for start in stride(from: 0, to: input.count, by: 1600) {
                    let u = try await engine.accept(Array(input[start..<min(start + 1600, input.count)]))
                    if u.isEndpoint {
                        let t = await engine.finishUtterance()
                        if !t.isEmpty { texts.append(t) }
                    }
                }
                let tail = await engine.finishUtterance()
                if !tail.isEmpty { texts.append(tail) }
                await engine.shutdown()
                print("STREAM \(name) \(label): \(texts.joined(separator: " / "))")
            }
        }
    }
}

extension EvaluationTests {
    static func sileroSegments(_ audio: [Float], threshold: Float, minSilence: Float = 0.5) -> [(start: Int, samples: [Float])] {
        let model = evalRoot.appendingPathComponent("dl-vad/silero_vad.onnx").path
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(model: model, threshold: threshold, minSilenceDuration: minSilence, minSpeechDuration: 0.25, maxSpeechDuration: 20)
        )
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 60)
        var out: [(Int, [Float])] = []
        func drain() {
            while !vad.isEmpty() {
                let s = vad.front()
                out.append((s.start, s.samples))
                vad.pop()
            }
        }
        for start in stride(from: 0, to: audio.count, by: 512) {
            vad.acceptWaveform(samples: Array(audio[start..<min(start + 512, audio.count)]))
            drain()
        }
        vad.flush()
        drain()
        return out
    }

    func testVADThresholdsAndTimeline() async throws {
        let url = try XCTUnwrap(wav, "set YUYIN_EVAL_WAV")
        let audio = try WAVFile.read(url)
        // Timeline from the streaming recognizer (decoded text = ground truth that speech exists).
        let engine = SherpaStreamingEngine(files: try ModelLocator.standard.streamingFiles())
        try await engine.prepare()
        var lastText = "", firstAt: Double?
        for start in stride(from: 0, to: audio.count, by: 1600) {
            let u = try await engine.accept(Array(audio[start..<min(start + 1600, audio.count)]))
            let t = Double(start + 1600) / 16000
            if !u.text.isEmpty && u.text != lastText {
                if firstAt == nil { firstAt = t }
                lastText = u.text
            }
            if u.isEndpoint {
                let text = await engine.finishUtterance()
                if !text.isEmpty { print(String(format: "TEXT %.1f-%.1f %@", firstAt ?? t, t, text)) }
                lastText = ""; firstAt = nil
            }
        }
        for threshold: Float in [0.5, 0.35, 0.2] {
            let segs = Self.sileroSegments(audio, threshold: threshold)
            print("SILERO th=\(threshold): " + segs.map { String(format: "%.1f-%.1f", Double($0.start) / 16000, Double($0.start + $0.samples.count) / 16000) }.joined(separator: " "))
        }
    }
}

extension EvaluationTests {
    func testFrameLevels() throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        var line = ""
        for (i, start) in stride(from: 0, to: min(audio.count, 16000 * 40), by: 1600).enumerated() {
            let r = AudioSpec.rms(audio[start..<min(start + 1600, audio.count)])
            line += String(format: "%4.1f:%.3f ", Double(i) / 10, r)
            if i % 10 == 9 { print("LV " + line); line = "" }
        }
        // 20 ms frame peaks inside one pause (11.0-12.3 s)
        var spikes = ""
        for start in stride(from: 16000 * 11, to: 16000 * 12, by: 320) {
            spikes += String(format: "%.3f ", AudioSpec.rms(audio[start..<start + 320]))
        }
        print("PAUSE20ms " + spikes)
    }
}

extension EvaluationTests {
    /// Per-sentence comparison of correctors on a real recording (segments from our segmenter).
    func testCorrectorComparison() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        var seg = UtteranceSegmenter()
        var segments: [Segment] = []
        for start in stride(from: 0, to: audio.count, by: 1600) {
            segments += seg.push(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        if let tail = seg.cut(), tail.speechMs > 0 { segments.append(tail) }

        var candidates: [(String, any CorrectorASREngine)] = []
        let std = ModelLocator.standard
        if std.isInstalled(.senseVoice) {
            candidates.append(("SenseVoice", SherpaOfflineCorrector(kind: .senseVoice, files: try std.offlineFiles(.senseVoice))))
        }
        if std.isInstalled(.senseVoiceANE) {
            candidates.append(("SenseVoice-ANE", FluidSenseVoiceCorrector(directory: std.directory(for: .senseVoiceANE))))
        }
        for (name, prefix, kind, model) in [
            ("Paraformer", "sherpa-onnx-paraformer-zh-2023", SherpaOfflineCorrector.Kind.paraformer, ModelKind.paraformer),
            ("FunASR-Nano", "sherpa-onnx-funasr-nano", .funASRNano, .funASRNano),
            ("Qwen3-ASR", "sherpa-onnx-qwen3-asr", .qwen3, .qwen3ASR),
        ] {
            if let dir = Self.dir(prefix), let files = try? std.offlineFiles(model, in: dir) {
                candidates.append((name, SherpaOfflineCorrector(kind: kind, files: files)))
            }
        }
        var timings: [String: Double] = [:]
        for (name, engine) in candidates {
            let t0 = Date()
            try await engine.prepare()
            print(String(format: "LOAD %@ %.1fs", name, Date().timeIntervalSince(t0)))
        }
        let speechSeconds = segments.reduce(0) { $0 + Double($1.samples.count) / 16000 }
        for s in segments {
            print(String(format: "SEG %.2f-%.2f (%d ms voiced)", Double(s.speechStartSample) / 16000, Double(s.speechEndSample) / 16000, s.speechMs))
            for (name, engine) in candidates {
                let t0 = Date()
                let raw = try await engine.correct(s.samples, hint: "")
                timings[name, default: 0] += Date().timeIntervalSince(t0)
                let norm = try await engine.correct(Self.normalize(s.samples), hint: "")
                print("   \(name.padding(toLength: 15, withPad: " ", startingAt: 0)) raw: \(raw) | norm: \(norm)")
            }
        }
        for (name, t) in timings.sorted(by: { $0.key < $1.key }) {
            print(String(format: "RTF %@ %.3f (%.1fs for %.1fs audio)", name, t / speechSeconds, t, speechSeconds))
        }
        for (_, engine) in candidates { await engine.shutdown() }
    }
}

extension EvaluationTests {
    /// Pairwise speaker-embedding similarity of every segment (all one speaker in our samples).
    func testSpeakerSimilarity() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        var seg = UtteranceSegmenter()
        var segments: [Segment] = []
        for start in stride(from: 0, to: audio.count, by: 1600) {
            segments += seg.push(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let model = try ModelLocator.standard.singleModel(.speakerEmbedding)
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: 2)
        let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
        var embeddings: [(String, [Float])] = []
        for s in segments {
            let stream = extractor.createStream()
            stream.acceptWaveform(samples: s.samples, sampleRate: 16000)
            stream.inputFinished()
            guard extractor.isReady(stream: stream) else { continue }
            let e = extractor.compute(stream: stream)
            let n = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
            embeddings.append((String(format: "%.1fs/%dms", Double(s.speechStartSample) / 16000, s.speechMs), e.map { $0 / n }))
        }
        for (i, a) in embeddings.enumerated() {
            var row = a.0.padding(toLength: 14, withPad: " ", startingAt: 0)
            for b in embeddings {
                row += String(format: " %5.2f", zip(a.1, b.1).reduce(0) { $0 + $1.0 * $1.1 })
            }
            print("SIM \(i) \(row)")
        }
    }
}

extension EvaluationTests {
    func testCrossSpeakerSimilarity() throws {
        let dir = ModelLocator.standard.directory(for: .senseVoice).appendingPathComponent("test_wavs")
        let model = try ModelLocator.standard.singleModel(.speakerEmbedding)
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: 2)
        let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
        func embed(_ samples: [Float]) -> [Float] {
            let stream = extractor.createStream()
            stream.acceptWaveform(samples: samples, sampleRate: 16000)
            stream.inputFinished()
            let e = extractor.compute(stream: stream)
            let n = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return e.map { $0 / n }
        }
        var items: [(String, [Float])] = []
        for name in ["zh", "en", "ja", "ko", "yue"] {
            let f = try AVAudioFile(forReading: dir.appendingPathComponent("\(name).wav"), commonFormat: .pcmFormatFloat32, interleaved: false)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: b)
            let s = Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
            // Two halves of the same file = same speaker; also a 1 s clip.
            items.append(("\(name)-a", embed(Array(s[..<(s.count / 2)]))))
            items.append(("\(name)-b", embed(Array(s[(s.count / 2)...]))))
            items.append(("\(name)-1s", embed(Array(s[(s.count / 3)..<(s.count / 3 + 16000)]))))
        }
        for a in items {
            var row = a.0.padding(toLength: 7, withPad: " ", startingAt: 0)
            for b in items { row += String(format: " %5.2f", zip(a.1, b.1).reduce(0) { $0 + $1.0 * $1.1 }) }
            print("X \(row)")
        }
    }
}

extension EvaluationTests {
    /// YUYIN_EVAL_IMPORT=1: import evaluated models into the app's model directory.
    func testImportEvaluatedModels() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YUYIN_EVAL_IMPORT"] == "1")
        let installer = ModelInstaller()
        for prefix in ["sherpa-onnx-paraformer-zh-2023", "sherpa-onnx-punct-ct-transformer", "sherpa-onnx-funasr-nano"] {
            let dir = try XCTUnwrap(Self.dir(prefix), prefix)
            let kind = try await installer.importFolder(dir)
            print("IMPORTED \(prefix) → \(kind) installed=\(ModelLocator.standard.isInstalled(kind))")
        }
    }

    /// The production corrector stack (guard + punctuation) on every sentence.
    func testProductionCorrector() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        var seg = UtteranceSegmenter()
        var segments: [Segment] = []
        for start in stride(from: 0, to: audio.count, by: 1600) {
            segments += seg.push(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let engines = LocalEngines()
        let plan = try engines.resolveCorrector(.auto)
        let corrector = try XCTUnwrap(try engines.makeCorrector(plan))
        try await corrector.prepare()
        print("PLAN \(plan.title)")
        for s in segments {
            let text = try await corrector.correct(AudioSpec.normalizedForRecognition(s.samples), hint: "")
            print(String(format: "OUT %.2f-%.2f %@", Double(s.speechStartSample) / 16000, Double(s.speechEndSample) / 16000, text.isEmpty ? "（丢弃：非语音）" : text))
        }
        await corrector.shutdown()
    }
}

extension EvaluationTests {
    /// The whole live pipeline as the app runs it, fed with a recording.
    func testFullSessionReplay() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        let engines = LocalEngines()
        struct Provider: EngineProvider {
            let set: EngineSet
            func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
        }
        let set = EngineSet(
            streaming: try engines.makeStreaming(try engines.resolveStreaming(.auto)),
            corrector: try engines.makeCorrector(try engines.resolveCorrector(.auto)),
            speakerLabeler: engines.makeSpeakerLabeler()
        )
        let session = TranscriptionSession(provider: Provider(set: set), settings: AppSettings())
        try await session.start()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        for u in await session.stop() {
            print(String(format: "FINAL [%.1f-%.1f] spk=%@ %@", Double(u.startMs) / 1000, Double(u.endMs ?? 0) / 1000, u.speakerIndex.map(String.init) ?? "-", u.displayText))
        }
    }
}

extension EvaluationTests {
    /// Full session replay with one corrector (YUYIN_EVAL_CORRECTOR = sensevoice | ane | paraformer
    /// | firered | funasr | qwen3 | none). Models come from the app directory or YUYIN_EVAL_MODELS.
    func testSessionReplayWithCorrector() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        let name = ProcessInfo.processInfo.environment["YUYIN_EVAL_CORRECTOR"] ?? "paraformer"
        let std = ModelLocator.standard
        func files(_ kind: ModelKind, _ prefix: String) throws -> OfflineModelFiles {
            if std.isInstalled(kind) { return try std.offlineFiles(kind) }
            return try std.offlineFiles(kind, in: try XCTUnwrap(Self.dir(prefix), prefix))
        }
        let corrector: (any CorrectorASREngine)?
        switch name {
        case "sensevoice": corrector = SherpaOfflineCorrector(kind: .senseVoice, files: try std.offlineFiles(.senseVoice))
        case "sensevoice-en": corrector = SherpaOfflineCorrector(kind: .senseVoice, files: try std.offlineFiles(.senseVoice), language: "en")
        case "sensevoice-auto": corrector = SherpaOfflineCorrector(kind: .senseVoice, files: try std.offlineFiles(.senseVoice), language: "auto")
        case "ane": corrector = FluidSenseVoiceCorrector(directory: std.directory(for: .senseVoiceANE))
        case "paraformer": corrector = SherpaOfflineCorrector(kind: .paraformer, files: try files(.paraformer, "sherpa-onnx-paraformer-zh-2023"),
                                                              punctuationModel: try? std.singleModel(.punctuation))
        case "firered": corrector = SherpaOfflineCorrector(kind: .fireRed, files: try files(.fireRed, "sherpa-onnx-fire-red-asr"),
                                                           punctuationModel: try? std.singleModel(.punctuation))
        case "funasr": corrector = SherpaOfflineCorrector(kind: .funASRNano, files: try files(.funASRNano, "sherpa-onnx-funasr-nano"))
        case "funasr-zh": corrector = SherpaOfflineCorrector(kind: .funASRNano, files: try files(.funASRNano, "sherpa-onnx-funasr-nano"),
                                                             promptLanguage: "中文")
        case "qwen3": corrector = SherpaOfflineCorrector(kind: .qwen3, files: try files(.qwen3ASR, "sherpa-onnx-qwen3-asr"))
        case "production": corrector = try LocalEngines().makeCorrector(try LocalEngines().resolveCorrector(.auto))
        default: corrector = nil
        }
        struct Provider: EngineProvider {
            let set: EngineSet
            func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
        }
        let engines = LocalEngines()
        var settings = AppSettings()
        let env = ProcessInfo.processInfo.environment
        if let ms = env["YUYIN_EVAL_SILENCE"].flatMap(Int.init) { settings.silenceMs = ms }
        var segmentation = SegmenterConfig()
        if let ms = env["YUYIN_EVAL_ENDPOINT_SILENCE"].flatMap(Int.init) { segmentation.endpointSilenceMs = ms }
        if let ms = env["YUYIN_EVAL_BACKSTOP"].flatMap(Int.init) { segmentation.endpointBackstopMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT"].flatMap(Int.init) { segmentation.shortSentenceMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT_SILENCE"].flatMap(Int.init) { segmentation.shortSentenceSilenceMs = ms }
        var labeler: SherpaSpeakerLabeler?
        if env["YUYIN_EVAL_LABEL"] == "1" {
            var clusterer = OnlineSpeakerClusterer()
            if let t = env["YUYIN_EVAL_THRESHOLD"].flatMap(Float.init) { clusterer.threshold = t }
            if let ms = env["YUYIN_EVAL_MIN_NEW"].flatMap(Int.init) { clusterer.minNewSpeakerMs = ms }
            if let t = env["YUYIN_EVAL_SHORT_CLIP"].flatMap(Float.init) { clusterer.shortClipThreshold = t }
            labeler = SherpaSpeakerLabeler(model: try env["YUYIN_EVAL_SPEAKER_MODEL"] ?? std.singleModel(.speakerEmbedding), clusterer: clusterer)
        }
        let session = TranscriptionSession(
            provider: Provider(set: EngineSet(streaming: try engines.makeStreaming(.sherpa), corrector: corrector, speakerLabeler: labeler)),
            settings: settings,
            segmentation: segmentation
        )
        try await session.start()
        let t0 = Date()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let result = await session.stop()
        print(String(format: "CORRECTOR %@ silence %dms: %d sentences (%.1fs for %.1fs audio)",
                     name, settings.silenceMs, result.count, Date().timeIntervalSince(t0), Double(audio.count) / 16000))
        var previousEnd: Int?
        for u in result {
            // Pause before this sentence: short pauses at a split usually mean a sentence cut in two.
            let gap = previousEnd.map { String(format: "%4.2f", Double(u.startMs - $0) / 1000) } ?? "   -"
            let speaker = u.speakerIndex.map { "S\($0 + 1)" } ?? "-"
            print(String(format: "  [%5.1f-%5.1f] gap %@ %@ %@", Double(u.startMs) / 1000, Double(u.endMs ?? 0) / 1000, gap, labeler == nil ? "" : speaker, u.displayText))
            print("          live: \(u.partial)")
            previousEnd = u.endMs
        }
        let starts = result.map(\.startMs), ends = result.map { $0.endMs ?? $0.startMs }
        let tightSplits = zip(ends.dropLast(), starts.dropFirst()).filter { $1 - $0 < 350 }.count
        let fragments = result.filter { TextFilter.contentUnits($0.displayText) <= 3 }.count
        let longest = zip(starts, ends).map { $1 - $0 }.max() ?? 0
        print(String(format: "SUMMARY endpoint %d/%d short %d/%d: %d sentences, %d splits with <0.35s pause, %d fragments (≤3 units), longest %.1fs",
                     segmentation.endpointSilenceMs, segmentation.endpointBackstopMs, segmentation.shortSentenceMs,
                     segmentation.shortSentenceSilenceMs, result.count, tightSplits, fragments, Double(longest) / 1000))
    }
}

extension EvaluationTests {
    /// Speaker embedding models on labeled recordings.
    ///
    ///     YUYIN_EVAL_SPEAKER_SET=<json: [{"wav": path, "speaker": name, "ranges": [[s, e], …]}]>
    ///     YUYIN_EVAL_SPEAKER_MODELS=<a.onnx,b.onnx>   (default: the installed model)
    ///
    /// Prints, per model and input (whole segment / voiced part only): same- vs different-speaker
    /// similarity, the equal error rate, and online clustering of an interleaved "conversation".
    func testSpeakerModelComparison() throws {
        struct Item: Decodable { let wav: String; let speaker: String; let ranges: [[Double]]? }
        struct Clip { let speaker: String; let source: String; let whole: [Float]; let voiced: [Float]; let speechMs: Int }
        let env = ProcessInfo.processInfo.environment
        let setURL = URL(fileURLWithPath: try XCTUnwrap(env["YUYIN_EVAL_SPEAKER_SET"], "set YUYIN_EVAL_SPEAKER_SET"))
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: setURL))

        var segmentsByWav: [String: [Segment]] = [:]
        var clips: [Clip] = []
        for item in items {
            if segmentsByWav[item.wav] == nil {
                let audio = try WAVFile.read(URL(fileURLWithPath: item.wav))
                var seg = UtteranceSegmenter()
                var out: [Segment] = []
                for start in stride(from: 0, to: audio.count, by: 1600) {
                    out += seg.push(Array(audio[start..<min(start + 1600, audio.count)]))
                }
                if let last = seg.cut() { out.append(last) }
                segmentsByWav[item.wav] = out
            }
            let source = URL(fileURLWithPath: item.wav).deletingLastPathComponent().lastPathComponent
            for s in segmentsByWav[item.wav] ?? [] where s.speechMs >= 500 {
                let a = Double(s.speechStartSample) / 16000, b = Double(s.speechEndSample) / 16000
                guard item.ranges?.contains(where: { a >= $0[0] && b <= $0[1] }) ?? true else { continue }
                let pad = 1600
                let from = max(s.startSample, s.speechStartSample - pad) - s.startSample
                let to = min(s.endSample, s.speechEndSample + pad) - s.startSample
                guard to - from >= 8000 else { continue }
                clips.append(Clip(speaker: item.speaker, source: source, whole: s.samples,
                                  voiced: Array(s.samples[from..<to]), speechMs: s.speechMs))
            }
        }
        let speakers = Array(Set(clips.map(\.speaker))).sorted()
        print("CLIPS " + speakers.map { s in "\(s) \(clips.filter { $0.speaker == s }.count)" }.joined(separator: ", "))

        // A conversation: speakers take turns of 1–3 sentences.
        var queues = speakers.map { s in clips.indices.filter { clips[$0].speaker == s } }
        var order: [Int] = []
        var turn = 0
        while queues.contains(where: { !$0.isEmpty }) {
            let q = turn % queues.count
            for _ in 0..<(1 + turn % 3) where !queues[q].isEmpty { order.append(queues[q].removeFirst()) }
            turn += 1
        }

        let installed = try ModelLocator.standard.singleModel(.speakerEmbedding)
        let models = env["YUYIN_EVAL_SPEAKER_MODELS"].map { $0.split(separator: ",").map(String.init) } ?? [installed]
        for model in models {
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: 4)
            let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            func embed(_ x: [Float]) -> [Float]? {
                let stream = extractor.createStream()
                stream.acceptWaveform(samples: x, sampleRate: 16000)
                stream.inputFinished()
                guard extractor.isReady(stream: stream) else { return nil }
                let e = extractor.compute(stream: stream)
                let n = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
                return n > 0 ? e.map { $0 / n } : nil
            }
            let name = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
            for variant in ["whole", "voiced"] {
                let t0 = Date()
                let embs = clips.map { embed(variant == "whole" ? $0.whole : $0.voiced) }
                let elapsed = Date().timeIntervalSince(t0)
                var same: [Float] = [], diff: [Float] = [], hard: [Float] = []
                for i in clips.indices {
                    for j in (i + 1)..<clips.count {
                        guard let a = embs[i], let b = embs[j] else { continue }
                        let s = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                        if clips[i].speaker == clips[j].speaker {
                            same.append(s)
                        } else {
                            diff.append(s)
                            if clips[i].source == clips[j].source { hard.append(s) }
                        }
                    }
                }
                // Equal error rate: threshold where false accepts = false rejects.
                var eer: Float = 1, eerAt: Float = 0
                for t in stride(from: Float(-0.2), through: 1, by: 0.01) {
                    let far = Float(diff.filter { $0 >= t }.count) / Float(max(1, diff.count))
                    let frr = Float(same.filter { $0 < t }.count) / Float(max(1, same.count))
                    if abs(far - frr) < 0.02 || far < frr {
                        if max(far, frr) < eer { eer = max(far, frr); eerAt = t }
                        if far < frr { break }
                    }
                }
                func mean(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count) }
                print(String(format: "MODEL %@ [%@] %.1fs: same %.2f (p10 %.2f), different %.2f (p90 %.2f), same-recording different %.2f (max %.2f); EER %.1f%% at %.2f",
                             name, variant, elapsed, mean(same), same.sorted()[same.count / 10], mean(diff), diff.sorted()[diff.count * 9 / 10],
                             mean(hard), hard.max() ?? 0, eer * 100, eerAt))

                for threshold in [Float(0.3), 0.35, 0.4, 0.45, 0.5, 0.55, 0.6] {
                    var clusterer = OnlineSpeakerClusterer(threshold: threshold)
                    var assigned: [Int: Int] = [:]
                    for i in order {
                        if let e = embs[i], let c = clusterer.assign(e, speechMs: clips[i].speechMs) { assigned[i] = c }
                    }
                    var tp = 0, fp = 0, fn = 0
                    for i in clips.indices {
                        for j in (i + 1)..<clips.count {
                            let truth = clips[i].speaker == clips[j].speaker
                            let predicted = assigned[i] != nil && assigned[i] == assigned[j]
                            if truth && predicted { tp += 1 } else if predicted { fp += 1 } else if truth { fn += 1 }
                        }
                    }
                    let p = Double(tp) / Double(max(1, tp + fp)), r = Double(tp) / Double(max(1, tp + fn))
                    print(String(format: "  threshold %.2f: %d speakers (truth %d), pair precision %.2f recall %.2f F1 %.2f, unlabeled %d",
                                 threshold, clusterer.speakerCount, speakers.count, p, r, 2 * p * r / max(1e-9, p + r), clips.count - assigned.count))
                }
            }
        }
    }
}

extension EvaluationTests {
    /// Speaker labels of the live pipeline (and of the after-recording analysis) against a
    /// reference RTTM, e.g. an AMI meeting.
    ///
    ///     YUYIN_EVAL_WAV=<16 kHz mono wav> YUYIN_EVAL_RTTM=<rttm> [YUYIN_EVAL_LIMIT_SEC=600]
    ///     [YUYIN_EVAL_SPEAKER_MODEL=<onnx>] [YUYIN_EVAL_THRESHOLD=0.4] [YUYIN_EVAL_DIARIZE=1]
    ///     plus the segmentation knobs of `testSessionReplayWithCorrector`.
    func testSpeakerReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        var audio = try WAVFile.read(try XCTUnwrap(wav))
        if let limit = env["YUYIN_EVAL_LIMIT_SEC"].flatMap(Double.init) { audio = Array(audio.prefix(Int(limit * 16000))) }
        let duration = Double(audio.count) / 16000
        let reference: [(start: Double, end: Double, speaker: String)] = try String(contentsOfFile: try XCTUnwrap(env["YUYIN_EVAL_RTTM"]), encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                let f = line.split(separator: " ")
                guard f.count > 7, let s = Double(f[3]), let d = Double(f[4]), s < duration else { return nil }
                return (s, min(s + d, duration), String(f[7]))
            }

        let model = try env["YUYIN_EVAL_SPEAKER_MODEL"] ?? ModelLocator.standard.singleModel(.speakerEmbedding)
        var clusterer = OnlineSpeakerClusterer()
        if let t = env["YUYIN_EVAL_THRESHOLD"].flatMap(Float.init) { clusterer.threshold = t }
        if let ms = env["YUYIN_EVAL_MIN_NEW"].flatMap(Int.init) { clusterer.minNewSpeakerMs = ms }
        var segmentation = SegmenterConfig()
        if let ms = env["YUYIN_EVAL_ENDPOINT_SILENCE"].flatMap(Int.init) { segmentation.endpointSilenceMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT"].flatMap(Int.init) { segmentation.shortSentenceMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT_SILENCE"].flatMap(Int.init) { segmentation.shortSentenceSilenceMs = ms }
        var settings = AppSettings()
        if let ms = env["YUYIN_EVAL_SILENCE"].flatMap(Int.init) { settings.silenceMs = ms }

        struct Provider: EngineProvider {
            let set: EngineSet
            func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
        }
        let engines = LocalEngines()
        let session = TranscriptionSession(
            provider: Provider(set: EngineSet(streaming: try engines.makeStreaming(.sherpa), corrector: nil,
                                              speakerLabeler: SherpaSpeakerLabeler(model: model, clusterer: clusterer))),
            settings: settings, segmentation: segmentation
        )
        try await session.start()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let utterances = await session.stop()
        let name = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
        print("REPLAY \(name) threshold \(clusterer.threshold) short \(segmentation.shortSentenceMs)/\(segmentation.shortSentenceSilenceMs) silence \(settings.silenceMs)")
        Self.scoreSpeakers(utterances.map { ($0.startMs, $0.endMs ?? $0.startMs, $0.speakerIndex) }, reference: reference, label: "live")

        if env["YUYIN_EVAL_DIARIZE"] == "1" {
            for threshold in [Float(0.5), 0.6, 0.7] {
                let diarizer = SherpaSessionDiarizer(segmentationModel: try ModelLocator.standard.singleModel(.speakerSegmentation),
                                                     embeddingModel: model, clusterThreshold: threshold)
                try await diarizer.prepare(expectedSpeakers: 0)
                let t0 = Date()
                let segments = try await diarizer.diarize(audio)
                let mapping = SpeakerMapping.map(utterances, segments: segments)
                Self.scoreSpeakers(utterances.map { ($0.startMs, $0.endMs ?? $0.startMs, mapping[$0.id] ?? nil) }, reference: reference,
                                   label: String(format: "analysis %.1f (%.0fs)", threshold, Date().timeIntervalSince(t0)))
                await diarizer.shutdown()
            }
        }
    }

    /// Per sentence: its main reference speaker (by overlap); "mixed" when that speaker covers
    /// under 70% of the talk inside it. Accuracy uses the best one-to-one cluster↔speaker match.
    static func scoreSpeakers(_ items: [(startMs: Int, endMs: Int, speaker: Int?)], reference: [(start: Double, end: Double, speaker: String)], label: String) {
        var cells: [Int: [String: Double]] = [:]
        var total = 0.0, mixed = 0, counted = 0, unlabeled = 0.0
        var truthLabels: [(Int?, String)] = []
        for item in items {
            let a = Double(item.startMs) / 1000, b = Double(max(item.endMs, item.startMs + 1)) / 1000
            var talk: [String: Double] = [:]
            for r in reference {
                let o = min(b, r.end) - max(a, r.start)
                if o > 0 { talk[r.speaker, default: 0] += o }
            }
            guard let main = talk.max(by: { $0.value < $1.value }) else { continue }
            counted += 1
            let all = talk.values.reduce(0, +)
            if main.value / all < 0.7 { mixed += 1 }
            total += main.value
            truthLabels.append((item.speaker, main.key))
            if let s = item.speaker { cells[s, default: [:]][main.key, default: 0] += main.value } else { unlabeled += main.value }
        }
        // Greedy one-to-one matching on the largest overlaps.
        var flat = cells.flatMap { c in c.value.map { (c.key, $0.key, $0.value) } }.sorted { $0.2 > $1.2 }
        var usedC: Set<Int> = [], usedS: Set<String> = []
        var matched = 0.0
        while let top = flat.first {
            flat.removeFirst()
            guard !usedC.contains(top.0), !usedS.contains(top.1) else { continue }
            usedC.insert(top.0); usedS.insert(top.1); matched += top.2
        }
        var tp = 0, fp = 0, fn = 0
        for i in truthLabels.indices {
            for j in (i + 1)..<truthLabels.count {
                let truth = truthLabels[i].1 == truthLabels[j].1
                let predicted = truthLabels[i].0 != nil && truthLabels[i].0 == truthLabels[j].0
                if truth && predicted { tp += 1 } else if predicted { fp += 1 } else if truth { fn += 1 }
            }
        }
        let p = Double(tp) / Double(max(1, tp + fp)), r = Double(tp) / Double(max(1, tp + fn))
        let speakers = Set(truthLabels.map(\.1)).count
        print(String(format: "  %@: %d sentences, %d mixed (%.0f%%), %d clusters for %d speakers, accuracy %.1f%%, unlabeled %.1f%%, pair F1 %.2f",
                     label, counted, mixed, 100 * Double(mixed) / Double(max(1, counted)), cells.count, speakers,
                     100 * matched / max(1e-9, total), 100 * unlabeled / max(1e-9, total), 2 * p * r / max(1e-9, p + r)))
    }
}

extension EvaluationTests {
    /// Clustering lab: segments a meeting once, embeds every sentence, then scores clustering
    /// methods offline against the RTTM. Same env as `testSpeakerReplay`, plus
    /// YUYIN_EVAL_SPEAKER_MODELS (comma-separated) to compare models.
    func testSpeakerClusteringLab() async throws {
        let env = ProcessInfo.processInfo.environment
        var audio = try WAVFile.read(try XCTUnwrap(wav))
        if let limit = env["YUYIN_EVAL_LIMIT_SEC"].flatMap(Double.init) { audio = Array(audio.prefix(Int(limit * 16000))) }
        let duration = Double(audio.count) / 16000
        let reference: [(start: Double, end: Double, speaker: String)] = try String(contentsOfFile: try XCTUnwrap(env["YUYIN_EVAL_RTTM"]), encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                let f = line.split(separator: " ")
                guard f.count > 7, let s = Double(f[3]), let d = Double(f[4]), s < duration else { return nil }
                return (s, min(s + d, duration), String(f[7]))
            }
        var segmentation = SegmenterConfig()
        if let ms = env["YUYIN_EVAL_ENDPOINT_SILENCE"].flatMap(Int.init) { segmentation.endpointSilenceMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT"].flatMap(Int.init) { segmentation.shortSentenceMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT_SILENCE"].flatMap(Int.init) { segmentation.shortSentenceSilenceMs = ms }
        var settings = AppSettings()
        if let ms = env["YUYIN_EVAL_SILENCE"].flatMap(Int.init) { settings.silenceMs = ms }
        struct Provider: EngineProvider {
            let set: EngineSet
            func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
        }
        let session = TranscriptionSession(
            provider: Provider(set: EngineSet(streaming: try LocalEngines().makeStreaming(.sherpa), corrector: nil)),
            settings: settings, segmentation: segmentation
        )
        try await session.start()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let utterances = await session.stop().sorted { $0.startMs < $1.startMs }
        print(String(format: "LAB %.0fs, silence %d, short %d/%d: %d sentences, %d reference turns",
                     duration, settings.silenceMs, segmentation.shortSentenceMs, segmentation.shortSentenceSilenceMs,
                     utterances.count, reference.count))

        let installed = try ModelLocator.standard.singleModel(.speakerEmbedding)
        let models = env["YUYIN_EVAL_SPEAKER_MODELS"].map { $0.split(separator: ",").map(String.init) } ?? [installed]
        for model in models {
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: 4)
            let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            func embed(_ from: Int, _ to: Int) -> [Float]? {
                let a = max(0, from), b = min(audio.count, to)
                guard b - a >= 4000 else { return nil }
                let stream = extractor.createStream()
                stream.acceptWaveform(samples: Array(audio[a..<b]), sampleRate: 16000)
                stream.inputFinished()
                guard extractor.isReady(stream: stream) else { return nil }
                let e = extractor.compute(stream: stream)
                let n = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
                return n > 0 ? e.map { $0 / n } : nil
            }
            let name = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
            // "voiced": the sentence's speech ±0.1 s (what the clusterer should hear).
            var spans = utterances.map { ($0.startMs, $0.endMs ?? $0.startMs) }
            if env["YUYIN_EVAL_SPLIT"] == "1" {
                // Speaker changes inside a sentence: local pyannote diarization on its audio.
                let splitThreshold = env["YUYIN_EVAL_SPLIT_THRESHOLD"].flatMap(Float.init) ?? 0.5
                let minPiece = env["YUYIN_EVAL_SPLIT_MIN"].flatMap(Int.init) ?? 1000
                var dconfig = sherpaOnnxOfflineSpeakerDiarizationConfig(
                    segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                        pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                            model: try ModelLocator.standard.singleModel(.speakerSegmentation)), numThreads: 2),
                    embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: 2),
                    clustering: sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: splitThreshold)
                )
                let local = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &dconfig)
                var out: [(Int, Int)] = []
                var splitCount = 0
                let t0 = Date()
                for (a, b) in spans {
                    guard b - a >= 3000 else { out.append((a, b)); continue }
                    let from = max(0, a * 16 - 1600), to = min(audio.count, b * 16 + 1600)
                    let segs = local.process(samples: Array(audio[from..<to]))
                    var talk: [Int: Int] = [:]
                    for g in segs { talk[g.speaker, default: 0] += Int((g.end - g.start) * 1000) }
                    guard talk.count > 1, talk.values.filter({ $0 >= minPiece }).count > 1 else { out.append((a, b)); continue }
                    // Runs of one speaker; back-channels shorter than minPiece join their neighbour.
                    var runs: [(start: Int, end: Int, speaker: Int)] = []
                    for g in segs.sorted(by: { $0.start < $1.start }) {
                        let gs = from / 16 + Int(g.start * 1000), ge = from / 16 + Int(g.end * 1000)
                        if let last = runs.last, last.speaker == g.speaker || talk[g.speaker, default: 0] < minPiece {
                            runs[runs.count - 1].end = max(last.end, ge)
                        } else {
                            runs.append((gs, ge, g.speaker))
                        }
                    }
                    if runs.count > 1 { splitCount += 1 }
                    out += runs.map { (max(a, $0.start), min(b, $0.end)) }.filter { $0.1 > $0.0 }
                }
                print(String(format: "  split %d of %d sentences into %d pieces (%.1fs)", splitCount, spans.count, out.count, Date().timeIntervalSince(t0)))
                spans = out
            }
            // YUYIN_EVAL_WHOLE=1: from the previous sentence's end, like a contiguous segment.
            let whole = env["YUYIN_EVAL_WHOLE"] == "1"
            let embs = spans.indices.map { i in
                embed(whole ? (i > 0 ? spans[i - 1].1 * 16 + 3200 : 0) : spans[i].0 * 16 - 1600, spans[i].1 * 16 + 1600)
            }
            let speech = spans.map { max(0, $0.1 - $0.0) }
            func score(_ labels: [Int?], _ label: String) {
                Self.scoreSpeakers(zip(spans, labels).map { ($0.0, $0.1, $1) }, reference: reference, label: "\(name.prefix(28)) \(label)")
            }
            let thresholds = env["YUYIN_EVAL_THRESHOLDS"].map { $0.split(separator: ",").compactMap { Float(String($0)) } } ?? [0.3, 0.4, 0.5]
            let minNews = env["YUYIN_EVAL_MIN_NEWS"].map { $0.split(separator: ",").compactMap { Int(String($0)) } } ?? [1000]
            let shortClips = env["YUYIN_EVAL_SHORT_CLIPS"].map { $0.split(separator: ",").compactMap { Float(String($0)) } } ?? [0.2]
            let reliefs = env["YUYIN_EVAL_RELIEFS"].map { $0.split(separator: ",").compactMap { Float(String($0)) } } ?? [0]
            for t in thresholds { for minNew in minNews { for shortClip in shortClips { for relief in reliefs {
                var c = OnlineSpeakerClusterer(threshold: t, minNewSpeakerMs: minNew, shortClipThreshold: shortClip, shortClipRelief: relief)
                score(embs.indices.map { i in embs[i].flatMap { c.assign($0, speechMs: speech[i]) } },
                      String(format: "online %.2f new≥%dms short %.2f relief %.2f", t, minNew, shortClip, relief))
            } } } }
            if env["YUYIN_EVAL_SKIP_AHC"] == "1" { continue }
            for t in [Float(0.3), 0.4, 0.5, 0.6] {
                score(Self.agglomerate(embs, weights: speech, threshold: t), String(format: "AHC %.2f", t))
            }
        }
    }

    /// Average-linkage agglomerative clustering on cosine similarity.
    static func agglomerate(_ embs: [[Float]?], weights: [Int], threshold: Float) -> [Int?] {
        var clusters: [[Int]] = embs.indices.filter { embs[$0] != nil }.map { [$0] }
        func sim(_ a: [Int], _ b: [Int]) -> Float {
            var s: Float = 0
            for i in a { for j in b { s += zip(embs[i]!, embs[j]!).reduce(Float(0)) { $0 + $1.0 * $1.1 } } }
            return s / Float(a.count * b.count)
        }
        while clusters.count > 1 {
            var best: (Int, Int, Float) = (0, 0, -2)
            for i in clusters.indices { for j in (i + 1)..<clusters.count {
                let s = sim(clusters[i], clusters[j]); if s > best.2 { best = (i, j, s) }
            } }
            guard best.2 >= threshold else { break }
            clusters[best.0] += clusters[best.1]
            clusters.remove(at: best.1)
        }
        // Number by first appearance.
        clusters.sort { $0.min()! < $1.min()! }
        var out = [Int?](repeating: nil, count: embs.count)
        for (k, members) in clusters.enumerated() { for m in members { out[m] = k } }
        return out
    }
}

extension EvaluationTests {
    /// "重新分析说话人" on a saved recording (YUYIN_EVAL_MEETING=<meeting folder>), as the app does it.
    func testReanalyzeMeeting() async throws {
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["YUYIN_EVAL_MEETING"]))
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appendingPathComponent("meeting.json")))
        let audio = dir.appendingPathComponent("audio.wav")
        let labeler = try XCTUnwrap(LocalEngines().makeSpeakerLabeler())
        try await labeler.prepare(expectedSpeakers: 0)
        for u in meeting.utterances.sorted(by: { $0.startMs < $1.startMs }) where u.status == .final {
            let range = AudioSpec.samples(forMilliseconds: max(0, u.startMs - 100))..<AudioSpec.samples(forMilliseconds: (u.endMs ?? u.startMs) + 100)
            let clip = try WAVFile.read(audio, range: range)
            let speaker = clip.count >= 9600 ? try await labeler.assign(clip, speechMs: clip.count / 16 - 200) : nil
            print(String(format: "RE %6.1f %@ (was %@) %@", Double(u.startMs) / 1000, speaker.map { "S\($0 + 1)" } ?? "-",
                         u.speakerIndex.map { "S\($0 + 1)" } ?? "-", String(u.displayText.prefix(50))))
        }
        await labeler.shutdown()
    }
}
