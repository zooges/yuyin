import Foundation
import SherpaOnnx
import YuyinCore

/// Per-sentence speaker label: sherpa embedding + `OnlineSpeakerClusterer`.
public final class SherpaSpeakerLabeler: SpeakerLabeling, @unchecked Sendable {
    private let model: String
    private let queue = DispatchQueue(label: "app.yuyin.speaker.label", qos: .utility)
    private var extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?
    private let baseClusterer: OnlineSpeakerClusterer
    private var clusterer: OnlineSpeakerClusterer
    private let threads: Int

    /// `threads`: 1 while recording (two short windows a second); more for re-analysing a
    /// whole recording.
    public init(model: String, clusterer: OnlineSpeakerClusterer = OnlineSpeakerClusterer(), threads: Int = 1) {
        self.model = model
        baseClusterer = clusterer
        self.clusterer = clusterer
        self.threads = threads
    }

    public func prepare(expectedSpeakers: Int) async throws {
        let model = model
        try await SherpaRuntime.run(on: queue) { [self] in
            try SherpaRuntime.checkFiles([model], model: "speaker-embedding")
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: threads, provider: SherpaRuntime.provider)
            extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            clusterer = baseClusterer
            clusterer.maxSpeakers = max(0, expectedSpeakers)
        }
    }

    public func assign(_ samples: [Float], speechMs: Int) async throws -> Int? {
        try await SherpaRuntime.run(on: queue) { [self] in
            guard let extractor else { throw ASRError.notPrepared }
            let stream = extractor.createStream()
            stream.acceptWaveform(samples: samples, sampleRate: AudioSpec.sampleRate)
            stream.inputFinished()
            guard extractor.isReady(stream: stream) else { return nil }
            return clusterer.assign(extractor.compute(stream: stream), speechMs: speechMs)
        }
    }

    public func embed(_ samples: [Float]) async -> [Float]? {
        await SherpaRuntime.run(on: queue) { [self] in
            guard let extractor else { return nil }
            let stream = extractor.createStream()
            stream.acceptWaveform(samples: samples, sampleRate: AudioSpec.sampleRate)
            stream.inputFinished()
            guard extractor.isReady(stream: stream) else { return nil }
            return extractor.compute(stream: stream)
        }
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in extractor = nil }
    }
}
