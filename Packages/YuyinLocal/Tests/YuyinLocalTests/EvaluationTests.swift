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

        let models: [(String, ModelLocator, URL?)] = [
            ("x-asr-160ms", .standard, nil),
            ("x-asr-480ms", .standard, ModelLocator.standard.directory(for: .streamingXASR)),
        ]
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
        for prefix in ["sherpa-onnx-paraformer-zh-2023", "sherpa-onnx-punct-ct-transformer"] {
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
    /// | qwen-raw | qwen-large | production | none). Models come from the app directory or YUYIN_EVAL_MODELS.
    func testSessionReplayWithCorrector() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        let env = ProcessInfo.processInfo.environment
        let name = env["YUYIN_EVAL_CORRECTOR"] ?? "paraformer"
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
        case "qwen-raw":
            // Qwen3-ASR 1.7B without the hallucination guard around it.
            let files = try std.ggufFiles()
            corrector = LlamaASRCorrector(model: files.model, projector: files.projector, context: AppSettings().recognitionContext)
        case "production", "qwen-large":
            var local = LocalEngines()
            var context = AppSettings(vocabulary: AppSettings.parseVocabulary(env["YUYIN_EVAL_VOCAB"] ?? ""),
                                      contextNote: env["YUYIN_EVAL_NOTE"] ?? "").recognitionContext
            context?.selectsTerms = env["YUYIN_EVAL_TERMS"] != "all"
            local.context = env["YUYIN_EVAL_CONTEXT"] == "0" ? nil : context
            corrector = try local.makeCorrector(try local.resolveCorrector(name == "production" ? .auto : .qwen3ASRLarge))
        default: corrector = nil
        }
        struct Provider: EngineProvider {
            let set: EngineSet
            func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
        }
        let engines = LocalEngines()
        var settings = AppSettings()
        if let ms = env["YUYIN_EVAL_SILENCE"].flatMap(Int.init) { settings.silenceMs = ms }
        var segmentation = SegmenterConfig()
        if let ms = env["YUYIN_EVAL_ENDPOINT_SILENCE"].flatMap(Int.init) { segmentation.endpointSilenceMs = ms }
        if let ms = env["YUYIN_EVAL_BACKSTOP"].flatMap(Int.init) { segmentation.endpointBackstopMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT"].flatMap(Int.init) { segmentation.shortSentenceMs = ms }
        if let ms = env["YUYIN_EVAL_SHORT_SILENCE"].flatMap(Int.init) { segmentation.shortSentenceSilenceMs = ms }
        if let ms = env["YUYIN_EVAL_SENTENCE_CUT"].flatMap(Int.init) { segmentation.sentenceEndCutMs = ms }
        if let ms = env["YUYIN_EVAL_SENTENCE_OFFSET"].flatMap(Int.init) { segmentation.sentenceCutOffsetMs = ms }
        if let ms = env["YUYIN_EVAL_SENTENCE_REACH"].flatMap(Int.init) { segmentation.sentenceCutReachMs = ms }
        var labeler: SherpaSpeakerLabeler?
        if env["YUYIN_EVAL_LABEL"] == "1" {
            var clusterer = OnlineSpeakerClusterer()
            if let t = env["YUYIN_EVAL_THRESHOLD"].flatMap(Float.init) { clusterer.threshold = t }
            if let ms = env["YUYIN_EVAL_MIN_NEW"].flatMap(Int.init) { clusterer.minNewSpeakerMs = ms }
            if let t = env["YUYIN_EVAL_SHORT_CLIP"].flatMap(Float.init) { clusterer.shortClipThreshold = t }
            labeler = SherpaSpeakerLabeler(model: try env["YUYIN_EVAL_SPEAKER_MODEL"] ?? std.singleModel(.speakerEmbedding), clusterer: clusterer)
        }
        // YUYIN_EVAL_STREAMING=<model dir>: another streaming model; YUYIN_EVAL_VAD=energy: the old segmentation.
        let streaming = try env["YUYIN_EVAL_STREAMING"].map { SherpaStreamingEngine(files: try std.streamingFiles(in: URL(fileURLWithPath: $0))) }
            ?? engines.makeStreaming(engines.resolveStreaming(.auto))
        let voice = env["YUYIN_EVAL_VAD"] == "energy" ? nil : engines.makeVoiceDetector()
        let timed = corrector.map(TimedCorrector.init)
        let session = TranscriptionSession(
            provider: Provider(set: EngineSet(streaming: streaming, corrector: timed, speakerLabeler: labeler, voiceDetector: voice)),
            settings: settings,
            segmentation: segmentation
        )
        try await session.start()
        let t0 = Date()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let result = await session.stop()
        print(String(format: "CORRECTOR %@ VAD %@ silence %dms: %d sentences (%.1fs for %.1fs audio)",
                     name, voice == nil ? "energy" : "silero", settings.silenceMs, result.count,
                     Date().timeIntervalSince(t0), Double(audio.count) / 16000))
        if let timed { print(timed.summary) }
        if let out = env["YUYIN_EVAL_OUT"] {
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: out))
        }
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
    ///     [YUYIN_EVAL_SPEAKER_MODEL=<onnx>] [YUYIN_EVAL_THRESHOLD=0.4]
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
            provider: Provider(set: EngineSet(streaming: try engines.makeStreaming(engines.resolveStreaming(.auto)), corrector: nil,
                                              speakerLabeler: SherpaSpeakerLabeler(model: model, clusterer: clusterer),
                                              voiceDetector: env["YUYIN_EVAL_VAD"] == "energy" ? nil : engines.makeVoiceDetector())),
            settings: settings, segmentation: segmentation, speakerChanges: Self.speakerChanges(env)
        )
        try await session.start()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let utterances = await session.stop()
        let name = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
        print("REPLAY \(name) VAD \(env["YUYIN_EVAL_VAD"] ?? "silero") change \(env["YUYIN_EVAL_CHANGE"] ?? "0.5") threshold \(clusterer.threshold) short \(segmentation.shortSentenceMs)/\(segmentation.shortSentenceSilenceMs) silence \(settings.silenceMs)")
        Self.scoreSpeakers(utterances.map { ($0.startMs, $0.endMs ?? $0.startMs, $0.speakerIndex) }, reference: reference, label: "live")
    }

    /// YUYIN_EVAL_CHANGE=off | <similarity>: speaker changes inside a sentence.
    static func speakerChanges(_ env: [String: String]) -> SpeakerChangeDetector? {
        guard let value = env["YUYIN_EVAL_CHANGE"] else { return SpeakerChangeDetector() }
        guard let threshold = Float(value) else { return nil }
        var detector = SpeakerChangeDetector()
        detector.threshold = threshold
        return detector
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
            provider: Provider(set: EngineSet(streaming: try LocalEngines().makeStreaming(LocalEngines().resolveStreaming(.auto)), corrector: nil)),
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
            let spans = utterances.map { ($0.startMs, $0.endMs ?? $0.startMs) }
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
    /// Speaker changes inside a sentence, found by sliding-window embeddings: a window that no
    /// longer sounds like the sentence so far (twice in a row) starts a new piece. Pieces are then
    /// labeled with the production clusterer and scored against the RTTM.
    ///
    ///     YUYIN_EVAL_WAV=… YUYIN_EVAL_RTTM=… [YUYIN_EVAL_LIMIT_SEC=900] [YUYIN_EVAL_VAD=energy]
    ///     [YUYIN_EVAL_CHANGE_THRESHOLDS=0.2,0.3,0.4] [YUYIN_EVAL_CHANGE_WIN=1500] [YUYIN_EVAL_CHANGE_HOP=500]
    ///     [YUYIN_EVAL_CHANGE_CONFIRM=2] [YUYIN_EVAL_SPLIT_MIN=1500]
    func testSpeakerChangeLab() async throws {
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
        struct Provider: EngineProvider {
            let set: EngineSet
            func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
        }
        let engines = LocalEngines()
        let session = TranscriptionSession(
            provider: Provider(set: EngineSet(streaming: try engines.makeStreaming(engines.resolveStreaming(.auto)), corrector: nil,
                                              voiceDetector: env["YUYIN_EVAL_VAD"] == "energy" ? nil : engines.makeVoiceDetector())),
            settings: AppSettings()
        )
        try await session.start()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await session.ingest(Array(audio[start..<min(start + 1600, audio.count)]))
        }
        let spans = await session.stop().sorted { $0.startMs < $1.startMs }.map { ($0.startMs, $0.endMs ?? $0.startMs) }

        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: try ModelLocator.standard.singleModel(.speakerEmbedding), numThreads: 4)
        let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
        func embed(_ fromMs: Int, _ toMs: Int) -> [Float]? {
            let a = max(0, fromMs * 16), b = min(audio.count, toMs * 16)
            guard b - a >= 4000 else { return nil }
            let stream = extractor.createStream()
            stream.acceptWaveform(samples: Array(audio[a..<b]), sampleRate: 16000)
            stream.inputFinished()
            guard extractor.isReady(stream: stream) else { return nil }
            let e = extractor.compute(stream: stream)
            let n = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return n > 0 ? e.map { $0 / n } : nil
        }
        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            let n = a.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return n > 0 ? zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / n : 0
        }
        let win = env["YUYIN_EVAL_CHANGE_WIN"].flatMap(Int.init) ?? 1500
        let hop = env["YUYIN_EVAL_CHANGE_HOP"].flatMap(Int.init) ?? 500
        let confirm = env["YUYIN_EVAL_CHANGE_CONFIRM"].flatMap(Int.init) ?? 2
        let minPiece = env["YUYIN_EVAL_SPLIT_MIN"].flatMap(Int.init) ?? 1500
        // Window embeddings, computed once per sentence.
        let windows: [[(start: Int, emb: [Float])]] = spans.map { a, b in
            guard b - a >= 2 * minPiece else { return [] }
            return stride(from: a, through: b - win, by: hop).compactMap { t in embed(t, t + win).map { (t, $0) } }
        }

        func label(_ pieces: [(Int, Int)], _ name: String) {
            var clusterer = OnlineSpeakerClusterer()
            let labels = pieces.map { a, b in embed(a - 100, b + 100).flatMap { clusterer.assign($0, speechMs: b - a) } }
            Self.scoreSpeakers(zip(pieces, labels).map { ($0.0, $0.1, $1) }, reference: reference, label: name)
        }
        print(String(format: "CHANGE LAB %.0fs VAD %@: %d sentences", duration, env["YUYIN_EVAL_VAD"] ?? "silero", spans.count))
        label(spans, "no split")
        let thresholds = env["YUYIN_EVAL_CHANGE_THRESHOLDS"].map { $0.split(separator: ",").compactMap { Float(String($0)) } } ?? [0.2, 0.3, 0.4]
        for tau in thresholds {
            var pieces: [(Int, Int)] = []
            for (i, (a, b)) in spans.enumerated() {
                var pieceStart = a
                var profile: [Float]?
                var firstBelow: Int?
                var below = 0
                for w in windows[i] {
                    guard let p = profile else { profile = w.emb; continue }
                    if cosine(p, w.emb) < tau {
                        below += 1
                        firstBelow = firstBelow ?? w.start
                        if below >= confirm, let changed = firstBelow {
                            let boundary = changed + win / 2
                            if boundary - pieceStart >= minPiece && b - boundary >= minPiece {
                                pieces.append((pieceStart, boundary))
                                pieceStart = boundary
                                profile = w.emb
                            }
                            below = 0
                            firstBelow = nil
                        }
                    } else {
                        below = 0
                        firstBelow = nil
                        profile = zip(p, w.emb).map { $0 + $1 }
                    }
                }
                pieces.append((pieceStart, b))
            }
            label(pieces, String(format: "split τ %.2f (%d pieces)", tau, pieces.count))
        }
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

/// Per-sentence correction time, to see whether a corrector keeps up with speech.
final class TimedCorrector: CorrectorASREngine, @unchecked Sendable {
    private let inner: any CorrectorASREngine
    private var runs: [(audio: Double, wall: Double)] = []
    var providerID: String { inner.providerID }

    init(_ inner: any CorrectorASREngine) {
        self.inner = inner
    }

    func prepare() async throws { try await inner.prepare() }

    func correct(_ samples: [Float], hint: String) async throws -> String {
        let start = Date()
        defer { runs.append((Double(samples.count) / Double(AudioSpec.sampleRate), Date().timeIntervalSince(start))) }
        return try await inner.correct(samples, hint: hint)
    }

    func shutdown() async { await inner.shutdown() }

    var summary: String {
        let walls = runs.map(\.wall).sorted()
        guard !walls.isEmpty else { return "TIMING no sentences" }
        let audio = runs.map(\.audio).reduce(0, +)
        return String(format: "TIMING %d sentences: mean %.2fs, p90 %.2fs, max %.2fs per sentence; RTF %.3f",
                      walls.count, walls.reduce(0, +) / Double(walls.count), walls[walls.count * 9 / 10],
                      walls.last!, walls.reduce(0, +) / audio)
    }
}

extension EvaluationTests {
    /// `finishUtterance(keepingUntil:)` assumes token times restart at 0 after a reset.
    func testStreamingTimestampsRestartAfterReset() throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        let locator = ModelLocator.standard
        let dir = locator.directory(for: locator.isInstalled(.streamingXASR) ? .streamingXASR : .streamingXASRFast)
        let files = try locator.streamingFiles(in: dir)
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: files.tokens,
            transducer: sherpaOnnxOnlineTransducerModelConfig(encoder: files.encoder, decoder: files.decoder, joiner: files.joiner),
            numThreads: 2, modelType: ""
        )
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: modelConfig, enableEndpoint: false
        )
        let recognizer = SherpaOnnxRecognizer(config: &config)
        for (i, range) in [0..<96_000, 96_000..<192_000].enumerated() {
            recognizer.acceptWaveform(samples: Array(audio[range]), sampleRate: 16000)
            while recognizer.isReady() { recognizer.decode() }
            let r = recognizer.getResult()
            print("PART \(i): \(r.tokens.count) tokens, times \(r.timestamps.first ?? -1)…\(r.timestamps.last ?? -1): \(r.text)")
            recognizer.reset()
        }
    }
}

extension EvaluationTests {
    /// Every change the legal term correction makes to a saved recording (YUYIN_EVAL_MEETING=<folder>).
    func testTermLexiconOnMeeting() throws {
        let dir = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["YUYIN_EVAL_MEETING"]))
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appendingPathComponent("meeting.json")))
        let vocabulary = AppSettings.parseVocabulary(ProcessInfo.processInfo.environment["YUYIN_EVAL_VOCAB"] ?? "")
        let lexicon = AppSettings(vocabulary: vocabulary).termLexicon
        var lines: [String] = []
        for u in meeting.utterances {
            let before = u.displayText, after = lexicon.correct(before)
            guard before != after else { continue }
            lines.append("TERM \(before)\n  →  \(after)")
        }
        lines.append("TERMS changed \(lines.count) of \(meeting.utterances.count) sentences")
        // stdout of long test runs gets cut off; YUYIN_EVAL_OUT keeps the full list.
        if let out = ProcessInfo.processInfo.environment["YUYIN_EVAL_OUT"] {
            try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        lines.forEach { print($0) }
    }
}

extension EvaluationTests {
    /// Pauses the voice model hears in a recording, by length (YUYIN_EVAL_VAD_THRESHOLDS=0.5,0.6).
    func testVoiceModelPauses() async throws {
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        let thresholds = ProcessInfo.processInfo.environment["YUYIN_EVAL_VAD_THRESHOLDS"]?.split(separator: ",").compactMap { Float(String($0)) } ?? [0.5]
        for threshold in thresholds {
            let vad = SherpaVoiceDetector(model: try XCTUnwrap(SherpaVoiceDetector.bundledModel), threshold: threshold)
            try await vad.prepare()
            var decisions: [VoiceDecision] = []
            for start in stride(from: 0, to: audio.count, by: 1600) {
                decisions += await vad.detect(Array(audio[start..<min(start + 1600, audio.count)]))
            }
            var pauses: [Int] = [], run = 0, speech = 0
            for d in decisions {
                if d.isSpeech { if run > 0 { pauses.append(run) }; run = 0; speech += 512 } else { run += 512 }
            }
            let ms = pauses.map { $0 / 16 }
            let buckets = [100, 150, 250, 450, 700, 1300]
            let counts = buckets.map { b in ms.filter { $0 >= b }.count }
            print(String(format: "VAD %.2f: speech %.0f%%, pauses ≥", threshold, 100 * Double(speech) / Double(audio.count))
                  + zip(buckets, counts).map { " \($0)ms:\($1)" }.joined())
        }
    }
}

extension EvaluationTests {
    /// How far live recognition falls behind, fed at real-time pace (YUYIN_EVAL_FAST=1: as fast
    /// as possible) with the production engines. Times every engine call that `ingest` waits for.
    func testIngestLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        let audio = try WAVFile.read(try XCTUnwrap(wav))
        let engines = LocalEngines()
        let clock = CallClock()
        let streaming = TimedStreaming(try engines.makeStreaming(engines.resolveStreaming(.auto)), clock)
        let labeler = env["YUYIN_EVAL_LABEL"] == "0" ? nil : engines.makeSpeakerLabeler().map { TimedLabeler($0, clock) }
        let voice = env["YUYIN_EVAL_VAD"] == "energy" ? nil : engines.makeVoiceDetector().map { TimedVoice($0, clock) }
        let corrector = env["YUYIN_EVAL_CORRECTOR"] == "none" ? nil : try engines.makeCorrector(engines.resolveCorrector(.auto))
        let session = TranscriptionSession(
            provider: StaticEngines(set: EngineSet(streaming: streaming, corrector: corrector, speakerLabeler: labeler, voiceDetector: voice)),
            settings: AppSettings(), speakerChanges: Self.speakerChanges(env)
        )
        try await session.start()
        let chunk = 1600
        let realtime = env["YUYIN_EVAL_FAST"] != "1"
        let t0 = Date()
        var lags: [Double] = []
        var worst: (lag: Double, at: Double) = (0, 0)
        for start in stride(from: 0, to: audio.count, by: chunk) {
            let end = min(start + chunk, audio.count)
            let audioTime = Double(end) / 16000
            if realtime {
                let wait = audioTime - Date().timeIntervalSince(t0)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            await session.ingest(Array(audio[start..<end]))
            let lag = Date().timeIntervalSince(t0) - audioTime
            lags.append(lag)
            if lag > worst.lag { worst = (lag, audioTime) }
        }
        let wall = Date().timeIntervalSince(t0)
        _ = await session.stop()
        let sorted = lags.sorted()
        print(String(format: "LATENCY %@ %.0fs audio in %.1fs: lag median %.2fs p90 %.2fs max %.2fs (at %.0fs), final lag %.2fs",
                     realtime ? "realtime" : "fast", Double(audio.count) / 16000, wall,
                     sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], worst.lag, worst.at, lags.last ?? 0))
        print(clock.report)
    }
}

private struct StaticEngines: EngineProvider {
    let set: EngineSet
    func makeEngines(for settings: AppSettings) async throws -> EngineSet { set }
}

/// Total / max time per engine call.
final class CallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stats: [String: (count: Int, total: Double, max: Double)] = [:]

    func time<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let start = Date()
        defer {
            let elapsed = Date().timeIntervalSince(start)
            lock.withLock {
                var s = stats[name] ?? (0, 0, 0)
                s.count += 1; s.total += elapsed; s.max = max(s.max, elapsed)
                stats[name] = s
            }
        }
        return try await body()
    }

    var report: String {
        lock.withLock {
            stats.sorted { $0.value.total > $1.value.total }.map {
                String(format: "  %-22@ %5d calls, total %6.2fs, mean %5.1fms, max %6.1fms", $0.key as NSString, $0.value.count,
                       $0.value.total, 1000 * $0.value.total / Double($0.value.count), 1000 * $0.value.max)
            }.joined(separator: "\n")
        }
    }
}

final class TimedStreaming: StreamingASREngine, @unchecked Sendable {
    private let inner: any StreamingASREngine
    private let clock: CallClock
    var providerID: String { inner.providerID }
    init(_ inner: any StreamingASREngine, _ clock: CallClock) { self.inner = inner; self.clock = clock }
    func prepare() async throws { try await inner.prepare() }
    func accept(_ samples: [Float]) async throws -> StreamingUpdate {
        try await clock.time(samples.count > 1600 ? "streaming.refeed" : "streaming.accept") { try await inner.accept(samples) }
    }
    func finishUtterance() async -> String { await clock.time("streaming.finish") { await inner.finishUtterance() } }
    func finishUtterance(keepingUntil seconds: Double) async -> String {
        await clock.time("streaming.finish") { await inner.finishUtterance(keepingUntil: seconds) }
    }
    func shutdown() async { await inner.shutdown() }
}

final class TimedLabeler: SpeakerLabeling, @unchecked Sendable {
    private let inner: any SpeakerLabeling
    private let clock: CallClock
    init(_ inner: any SpeakerLabeling, _ clock: CallClock) { self.inner = inner; self.clock = clock }
    func prepare(expectedSpeakers: Int) async throws { try await inner.prepare(expectedSpeakers: expectedSpeakers) }
    func assign(_ samples: [Float], speechMs: Int) async throws -> Int? {
        try await clock.time("labeler.assign (worker)") { try await inner.assign(samples, speechMs: speechMs) }
    }
    func embed(_ samples: [Float]) async -> [Float]? { await clock.time("labeler.embed") { await inner.embed(samples) } }
    func shutdown() async { await inner.shutdown() }
}

final class TimedVoice: VoiceActivityDetecting, @unchecked Sendable {
    private let inner: any VoiceActivityDetecting
    private let clock: CallClock
    init(_ inner: any VoiceActivityDetecting, _ clock: CallClock) { self.inner = inner; self.clock = clock }
    func prepare() async throws { try await inner.prepare() }
    func detect(_ samples: [Float]) async -> [VoiceDecision] { await clock.time("vad.detect") { await inner.detect(samples) } }
    func shutdown() async { await inner.shutdown() }
}

extension EvaluationTests {
    /// How long after a word is spoken it appears in the live text: per token, the audio position
    /// when it was first decoded minus its own time. YUYIN_EVAL_STREAMING_DIRS=<dir,dir…>.
    func testStreamingEmissionDelay() throws {
        let env = ProcessInfo.processInfo.environment
        let audio = Array(try WAVFile.read(try XCTUnwrap(wav)).prefix(16000 * 90))
        let dirs = try XCTUnwrap(env["YUYIN_EVAL_STREAMING_DIRS"]).split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        for dir in dirs {
            let files = try ModelLocator.standard.streamingFiles(in: dir)
            let modelConfig = sherpaOnnxOnlineModelConfig(
                tokens: files.tokens,
                transducer: sherpaOnnxOnlineTransducerModelConfig(encoder: files.encoder, decoder: files.decoder, joiner: files.joiner),
                numThreads: 4, modelType: ""
            )
            var config = sherpaOnnxOnlineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: modelConfig, enableEndpoint: false
            )
            let recognizer = SherpaOnnxRecognizer(config: &config)
            var seen = 0
            var delays: [Double] = []
            let t0 = Date()
            for start in stride(from: 0, to: audio.count, by: 1600) {
                let end = min(start + 1600, audio.count)
                recognizer.acceptWaveform(samples: Array(audio[start..<end]), sampleRate: 16000)
                while recognizer.isReady() { recognizer.decode() }
                let times = recognizer.getResult().timestamps
                if times.count > seen {
                    let now = Double(end) / 16000
                    delays += times[seen...].map { now - Double($0) }
                    seen = times.count
                }
            }
            let compute = Date().timeIntervalSince(t0)
            let sorted = delays.sorted()
            guard !sorted.isEmpty else { continue }
            print(String(format: "EMIT %@: %d tokens, delay median %.2fs p90 %.2fs max %.2fs; compute RTF %.3f",
                         dir.lastPathComponent, sorted.count, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10],
                         sorted.last!, compute / (Double(audio.count) / 16000)))
        }
    }
}

extension EvaluationTests {
    /// Seconds from pressing record to listening, per engine, with the user's installed models.
    func testStartupTime() async throws {
        let engines = LocalEngines()
        var parts: [(String, () async throws -> Void)] = []
        let streaming = try engines.makeStreaming(engines.resolveStreaming(.auto))
        parts.append(("streaming \(streaming.providerID)", { try await streaming.prepare() }))
        if let corrector = try engines.makeCorrector(engines.resolveCorrector(.auto)) {
            parts.append(("corrector \(corrector.providerID)", { try await corrector.prepare() }))
        }
        if let labeler = engines.makeSpeakerLabeler() { parts.append(("speaker labeler", { try await labeler.prepare(expectedSpeakers: 0) })) }
        if let vad = engines.makeVoiceDetector() { parts.append(("voice detector", { try await vad.prepare() })) }
        for (name, prepare) in parts {
            let t0 = Date()
            try await prepare()
            print(String(format: "STARTUP %-28@ %.2fs", name as NSString, Date().timeIntervalSince(t0)))
        }
    }
}

extension EvaluationTests {
    /// Every token of the installed streaming model with its time, one pass without resets
    /// (YUYIN_EVAL_OUT=<json>), to see where its punctuation falls against the audio.
    func testStreamingTokenTimes() throws {
        let audio = Array(try WAVFile.read(try XCTUnwrap(wav)).prefix(16000 * 300))
        let locator = ModelLocator.standard
        let files = try locator.streamingFiles(in: locator.directory(for: .streamingXASR))
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: files.tokens,
            transducer: sherpaOnnxOnlineTransducerModelConfig(encoder: files.encoder, decoder: files.decoder, joiner: files.joiner),
            numThreads: 4, modelType: ""
        )
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: modelConfig, enableEndpoint: false
        )
        let recognizer = SherpaOnnxRecognizer(config: &config)
        var emitted: [Double] = []
        for start in stride(from: 0, to: audio.count, by: 1600) {
            let end = min(start + 1600, audio.count)
            recognizer.acceptWaveform(samples: Array(audio[start..<end]), sampleRate: 16000)
            while recognizer.isReady() { recognizer.decode() }
            let count = recognizer.getResult().tokens.count
            while emitted.count < count { emitted.append(Double(end) / 16000) }
        }
        let result = recognizer.getResult()
        let rows = zip(zip(result.tokens, result.timestamps), emitted).map { ["token": $0.0.0, "time": Double($0.0.1), "emitted": $0.1] as [String: Any] }
        let out = try XCTUnwrap(ProcessInfo.processInfo.environment["YUYIN_EVAL_OUT"])
        try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: out))
    }
}

extension EvaluationTests {
    /// What the open sentence shows over time, fed at real-time pace with the production engines
    /// (YUYIN_EVAL_FROM / YUYIN_EVAL_SECONDS select a stretch): early corrections replace the
    /// live text while a long sentence is still being spoken.
    func testOpenSentenceOverTime() async throws {
        let env = ProcessInfo.processInfo.environment
        let all = try WAVFile.read(try XCTUnwrap(wav))
        let from = Int((Double(env["YUYIN_EVAL_FROM"] ?? "0") ?? 0) * 16000)
        let audio = Array(all[from..<min(all.count, from + Int((Double(env["YUYIN_EVAL_SECONDS"] ?? "40") ?? 40) * 16000))])
        var local = LocalEngines()
        local.context = AppSettings().recognitionContext
        let session = TranscriptionSession(
            provider: StaticEngines(set: EngineSet(
                streaming: try local.makeStreaming(local.resolveStreaming(.auto)),
                corrector: try local.makeCorrector(local.resolveCorrector(.auto)),
                voiceDetector: local.makeVoiceDetector()
            )),
            settings: AppSettings()
        )
        try await session.start()
        let t0 = Date()
        let watcher = Task {
            var last: [UUID: String] = [:]
            var lines: [String] = []
            for await event in session.events {
                guard case .upsert(let u) = event, last[u.id] != u.displayText else { continue }
                last[u.id] = u.displayText
                lines.append(String(format: "OPEN %5.1fs [%@] %@", Date().timeIntervalSince(t0), u.status == .final ? "final" : "live ", u.displayText))
            }
            return lines
        }
        for start in stride(from: 0, to: audio.count, by: 1600) {
            let end = min(start + 1600, audio.count)
            let wait = Double(end) / 16000 - Date().timeIntervalSince(t0)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            await session.ingest(Array(audio[start..<end]))
        }
        _ = await session.stop()
        let lines = await watcher.value
        if let out = env["YUYIN_EVAL_OUT"] { try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

extension EvaluationTests {
    /// 润色 on a saved recording: YUYIN_EVAL_MEETING=<folder> [YUYIN_EVAL_POLISH_MODEL=<gguf>]
    /// [YUYIN_EVAL_FROM=<s>] [YUYIN_EVAL_SECONDS=<s>] YUYIN_EVAL_OUT=<txt>: before / after per sentence.
    func testPolishMeeting() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["YUYIN_EVAL_MEETING"]))
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appendingPathComponent("meeting.json")))
        let from = Int((Double(env["YUYIN_EVAL_FROM"] ?? "0") ?? 0) * 1000)
        let to = from + Int((Double(env["YUYIN_EVAL_SECONDS"] ?? "300") ?? 300) * 1000)
        let utterances = meeting.utterances.filter { $0.startMs >= from && $0.startMs < to }
        #if canImport(llama)
        let model = LlamaChatModel(model: try env["YUYIN_EVAL_POLISH_MODEL"] ?? ModelLocator.standard.polishModelFile())
        try await model.prepare()
        if let raw = env["YUYIN_EVAL_POLISH_RAW"],
           let first = TranscriptPolish.batches(TranscriptPolish.paragraphs(utterances, book: meeting.speakerBook)).first {
            let answer = try await model.complete(system: TranscriptPolish.system(background: nil, terms: []),
                                                  user: TranscriptPolish.user(first), maxTokens: 2000)
            try "\(first.count) paragraphs\n---\n\(answer)".write(toFile: raw, atomically: true, encoding: .utf8)
        }
        let t0 = Date()
        let settings = AppSettings()
        let polished = try await TranscriptPolish.run(
            utterances, book: meeting.speakerBook, model: model,
            background: settings.contextNote, terms: LegalVocabulary.terms.prefix(40).map { $0 }
        ) { _ in }
        let seconds = Date().timeIntervalSince(t0)
        let paragraphs = TranscriptPolish.paragraphs(utterances, book: meeting.speakerBook)
        var lines = paragraphs.map { p in "【\(p.speaker ?? "-")】原文：\(p.text)\n润色：\(polished[p.ids[0]] ?? "（保留原文）")\n" }
        let chars = utterances.reduce(0) { $0 + $1.displayText.count }
        lines.append(String(format: "POLISH %d paragraphs, %d chars in %.1fs (%.0f chars/s); %d polished, %d kept as said",
                            paragraphs.count, chars, seconds, Double(chars) / seconds,
                            paragraphs.filter { polished[$0.ids[0]] != nil }.count, paragraphs.filter { polished[$0.ids[0]] == nil }.count))
        try lines.joined(separator: "\n").write(toFile: try XCTUnwrap(env["YUYIN_EVAL_OUT"]), atomically: true, encoding: .utf8)
        await model.shutdown()
        #endif
    }
}
