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

    public init(model: String, clusterer: OnlineSpeakerClusterer = OnlineSpeakerClusterer()) {
        self.model = model
        baseClusterer = clusterer
        self.clusterer = clusterer
    }

    public func prepare(expectedSpeakers: Int) async throws {
        let model = model
        try await SherpaRuntime.run(on: queue) { [self] in
            try SherpaRuntime.checkFiles([model], model: "speaker-embedding")
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: model, numThreads: SherpaRuntime.threads)
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

/// Whole-recording diarization (pyannote segmentation + embedding clustering).
public final class SherpaSessionDiarizer: SessionDiarizer, @unchecked Sendable {
    private let segmentationModel: String
    private let embeddingModel: String
    private let queue = DispatchQueue(label: "app.yuyin.speaker.diarize", qos: .userInitiated)
    private var diarizer: SherpaOnnxOfflineSpeakerDiarizationWrapper?
    /// Cosine distance below which segments are the same speaker (when the count is unknown).
    private let clusterThreshold: Float

    public init(segmentationModel: String, embeddingModel: String, clusterThreshold: Float = 0.5) {
        self.segmentationModel = segmentationModel
        self.embeddingModel = embeddingModel
        self.clusterThreshold = clusterThreshold
    }

    public func prepare(expectedSpeakers: Int) async throws {
        let seg = segmentationModel
        let emb = embeddingModel
        let threshold = clusterThreshold
        try await SherpaRuntime.run(on: queue) { [self] in
            try SherpaRuntime.checkFiles([seg, emb], model: "speaker-diarization")
            var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
                segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                    pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: seg),
                    numThreads: SherpaRuntime.threads
                ),
                embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: emb, numThreads: SherpaRuntime.threads),
                clustering: sherpaOnnxFastClusteringConfig(numClusters: expectedSpeakers > 0 ? expectedSpeakers : -1, threshold: threshold)
            )
            diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        }
    }

    public func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] {
        try await SherpaRuntime.run(on: queue) { [self] in
            guard let diarizer else { throw ASRError.notPrepared }
            return diarizer.process(samples: samples).map {
                SpeakerSegment(startMs: Int($0.start * 1000), endMs: Int($0.end * 1000), speakerIndex: $0.speaker)
            }
        }
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in diarizer = nil }
    }
}
