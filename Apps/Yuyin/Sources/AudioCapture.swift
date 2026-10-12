import AVFoundation
import Foundation
import YuyinCore

struct CaptureChunk: Sendable {
    let samples: [Float]
    let peak: Float
    /// When the audio arrived (uptime ns), to see how far recognition runs behind.
    var captured = DispatchTime.now().uptimeNanoseconds
}

/// Combines the selected sources (microphone and/or system audio) into one ordered
/// 16 kHz mono `AsyncStream`, which is what the session's sequential-ingest contract needs.
final class AudioCapture: @unchecked Sendable {
    enum Event: Sendable {
        case interrupted
        case interruptionEnded
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let lock = NSLock()
    private var continuation: AsyncStream<CaptureChunk>.Continuation?
    private var microphone: MicrophoneSource?
    private var mixer: AudioMixer?
    #if os(macOS)
    private var system: AnyObject?
    #endif
    #if DEBUG
    private var replay: Thread?
    #endif

    static func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #else
        return await AVAudioApplication.requestRecordPermission()
        #endif
    }

    static var supportsSystemAudio: Bool {
        #if os(macOS)
        if #available(macOS 14.2, *) { return true }
        #endif
        return false
    }

    func start(source: AudioSourceChoice, appBundleID: String?) throws -> AsyncStream<CaptureChunk> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureChunk.self, bufferingPolicy: .unbounded)
        lock.withLock { self.continuation = continuation }
        let emit: @Sendable ([Float]) -> Void = { [weak self] samples in
            guard let self, !samples.isEmpty else { return }
            let chunk = CaptureChunk(samples: samples, peak: AudioSpec.peak(samples))
            self.lock.withLock { _ = self.continuation?.yield(chunk) }
        }

        #if DEBUG
        // -YuyinReplayWAV <16 kHz wav>: a recording instead of the microphone, at real-time pace.
        if let path = UserDefaults.standard.string(forKey: "YuyinReplayWAV") {
            let samples = try WAVFile.read(URL(fileURLWithPath: path))
            let thread = Thread {
                let start = DispatchTime.now().uptimeNanoseconds
                for offset in stride(from: 0, to: samples.count, by: 1600) where !Thread.current.isCancelled {
                    let end = min(offset + 1600, samples.count)
                    let due = start + UInt64(end) * 1_000_000_000 / UInt64(AudioSpec.sampleRate)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if due > now { Thread.sleep(forTimeInterval: Double(due - now) / 1e9) }
                    emit(Array(samples[offset..<end]))
                }
            }
            replay = thread
            thread.start()
            return stream
        }
        #endif
        do {
            let both = source.usesMicrophone && source.usesSystemAudio
            let mixer = both ? AudioMixer(emit: emit) : nil
            self.mixer = mixer

            if source.usesMicrophone {
                let mic = MicrophoneSource()
                mic.onEvent = { [weak self] in self?.onEvent?($0) }
                // Echo cancellation keeps the call's loudspeaker audio out of the mic in meeting mode.
                try mic.start(voiceProcessing: both) { samples in
                    if let mixer { mixer.pushMicrophone(samples) } else { emit(samples) }
                }
                microphone = mic
            }

            if source.usesSystemAudio {
                #if os(macOS)
                guard #available(macOS 14.2, *) else { throw CaptureError.systemAudioUnsupported }
                let target: SystemAudioSource.Target = source == .app
                    ? .app(bundleID: appBundleID ?? "")
                    : .allApps
                let tap = SystemAudioSource()
                try tap.start(target: target) { samples in
                    if let mixer { mixer.pushSystem(samples) } else { emit(samples) }
                }
                system = tap
                #else
                throw CaptureError.systemAudioUnsupported
                #endif
            }
        } catch {
            stop()
            throw error
        }
        return stream
    }

    func stop() {
        #if DEBUG
        replay?.cancel()
        replay = nil
        #endif
        microphone?.stop()
        microphone = nil
        #if os(macOS)
        if #available(macOS 14.2, *) { (system as? SystemAudioSource)?.stop() }
        system = nil
        #endif
        mixer?.flush()
        mixer = nil
        let cont: AsyncStream<CaptureChunk>.Continuation? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        cont?.finish()
    }

    enum CaptureError: Error, LocalizedError {
        case noInput
        case systemAudioUnsupported
        case appNotPlaying(String)
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInput: return "没有可用的麦克风输入"
            case .systemAudioUnsupported: return "录制系统声音需要 macOS 14.2 或更高版本（iOS 不支持）"
            case .appNotPlaying(let name): return "「\(name)」当前没有发出声音。请在会议或播放开始后再开始录音，或改用「系统声音」。"
            case .coreAudio(let step, let status): return "无法录制系统声音（\(step)：\(status)）。请在 系统设置 → 隐私与安全性 中允许录制系统音频。"
            }
        }
    }
}

/// Converts any PCM buffer to 16 kHz mono Float32, keeping converter state across calls.
final class PCMResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioSpec.sampleRate), channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: input, to: output) else { return nil }
        if input.channelCount > 1 {
            // Mix all input channels down instead of keeping only the first.
            converter.channelMap = [0]
            converter.downmix = true
        }
        self.converter = converter
        self.output = output
    }

    /// Same input-block pattern as k2-fsa's SherpaOnnxViewModel (feed each buffer once).
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Microphone via AVAudioEngine. Survives device / route changes and reports iOS interruptions.
final class MicrophoneSource: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "app.yuyin.capture.mic", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var voiceProcessing = false
    var onEvent: (@Sendable (AudioCapture.Event) -> Void)?

    func start(voiceProcessing: Bool, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        self.onSamples = onSamples
        self.voiceProcessing = voiceProcessing
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        if voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, iOS 17.0, *) {
                    // Don't turn the meeting's own audio down while we listen.
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                self.voiceProcessing = false
            }
        }
        try installTap()
        engine.prepare()
        try engine.start()
        observe()
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        // Let queued conversions drain before the stream ends.
        queue.sync {}
        onSamples = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = PCMResampler(from: format) else {
            throw AudioCapture.CaptureError.noInput
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.queue.async {
                guard let self, let samples = resampler.convert(buffer) else { return }
                self.onSamples?(samples)
            }
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        })
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            self?.onEvent?(type == .began ? .interrupted : .interruptionEnded)
        })
        #endif
    }

    /// Default input changed (headset plugged, mic switched): new format, new converter.
    private func restartAfterConfigurationChange() {
        guard onSamples != nil else { return }
        engine.stop()
        do {
            try installTap()
            engine.prepare()
            try engine.start()
        } catch {
            onEvent?(.interrupted)
        }
    }
}

/// Sums microphone and system audio sample-by-sample. Both sources run continuously;
/// if one stalls, the other is passed through after a short wait so nothing is lost.
final class AudioMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: [Float] = []
    private var system: [Float] = []
    private let emit: @Sendable ([Float]) -> Void
    private let maxLag = AudioSpec.samples(forMilliseconds: 400)

    init(emit: @escaping @Sendable ([Float]) -> Void) {
        self.emit = emit
    }

    func pushMicrophone(_ samples: [Float]) {
        lock.withLock { mic.append(contentsOf: samples) }
        drain()
    }

    func pushSystem(_ samples: [Float]) {
        lock.withLock { system.append(contentsOf: samples) }
        drain()
    }

    func flush() {
        drain(force: true)
    }

    private func drain(force: Bool = false) {
        let out: [Float] = lock.withLock {
            var count = min(mic.count, system.count)
            if force || max(mic.count, system.count) > maxLag {
                count = max(mic.count, system.count)
            }
            guard count > 0 else { return [] }
            var mixed = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let a = i < mic.count ? mic[i] : 0
                let b = i < system.count ? system[i] : 0
                mixed[i] = max(-1, min(1, a + b))
            }
            mic.removeFirst(min(count, mic.count))
            system.removeFirst(min(count, system.count))
            return mixed
        }
        if !out.isEmpty { emit(out) }
    }
}
