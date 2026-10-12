import Foundation
import SherpaOnnx
import YuyinCore

/// Silero VAD (bundled): speech by sound, not loudness. In the user's 2-hour meeting the
/// energy VAD counted continuous discussion at -25…-35 dBFS as seconds of "silence", so
/// sentences were cut inside words and quieter speakers merged into their neighbours.
public final class SherpaVoiceDetector: VoiceActivityDetecting, @unchecked Sendable {
    /// Silero's window at 16 kHz (32 ms).
    static let windowSize = 512
    /// sherpa keeps a speech run's audio until it ends; restart it after this much
    /// uninterrupted speech so the buffer stays bounded.
    static let maxSpeechRunSamples = AudioSpec.samples(forMilliseconds: 60_000)

    private let model: String
    private let threshold: Float
    private let queue = DispatchQueue(label: "app.yuyin.sherpa.vad", qos: .userInitiated)
    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?
    private var pending: [Float] = []
    private var position = 0
    private var speechRun = 0

    /// The model bundled with YuyinLocal.
    public static var bundledModel: String? {
        Bundle.module.path(forResource: "silero_vad", ofType: "onnx")
    }

    public init(model: String, threshold: Float = 0.5) {
        self.model = model
        self.threshold = threshold
    }

    public func prepare() async throws {
        let model = model
        let threshold = threshold
        try await SherpaRuntime.run(on: queue) { [self] in
            try SherpaRuntime.checkFiles([model], model: "Silero VAD")
            // Short minimums: the segmenter decides which pauses end a sentence. The huge
            // max duration keeps sherpa from raising its threshold during long speech.
            var config = sherpaOnnxVadModelConfig(
                sileroVad: sherpaOnnxSileroVadModelConfig(
                    model: model,
                    threshold: threshold,
                    minSilenceDuration: 0.1,
                    minSpeechDuration: 0.1,
                    windowSize: Self.windowSize,
                    maxSpeechDuration: 3_600
                ),
                sampleRate: Int32(AudioSpec.sampleRate),
                numThreads: 1
            )
            vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 70)
            pending = []
            position = 0
            speechRun = 0
        }
    }

    public func detect(_ samples: [Float]) async -> [VoiceDecision] {
        await SherpaRuntime.run(on: queue) { [self] in
            guard let vad else { return [] }
            pending.append(contentsOf: samples)
            var decisions: [VoiceDecision] = []
            var offset = 0
            while pending.count - offset >= Self.windowSize {
                // One window per call, so the state after each window is observable.
                vad.acceptWaveform(samples: Array(pending[offset..<(offset + Self.windowSize)]))
                offset += Self.windowSize
                position += Self.windowSize
                let speech = vad.isSpeechDetected()
                // Only the state is used; drop the finished segments sherpa collects.
                while !vad.isEmpty() { vad.pop() }
                speechRun = speech ? speechRun + Self.windowSize : 0
                if speechRun >= Self.maxSpeechRunSamples {
                    vad.reset()
                    speechRun = 0
                }
                decisions.append(VoiceDecision(endSample: position, isSpeech: speech))
            }
            pending.removeFirst(offset)
            return decisions
        }
    }

    public func shutdown() async {
        await SherpaRuntime.run(on: queue) { [self] in vad = nil }
    }
}
