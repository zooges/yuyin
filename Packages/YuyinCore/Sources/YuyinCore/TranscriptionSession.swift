import Foundation

/// One recording: streaming pass → segmentation → serial correction queue.
///
/// Contract:
/// - `ingest` must be called sequentially (one awaited call at a time, in capture order).
/// - Timestamps are audio time: derived from the number of ingested samples.
/// - `stop()` returns only after every queued correction and translation has finished.
/// - A session is single-use; `events` finishes after `stop()` (or a failed `start()`).
public actor TranscriptionSession {
    public nonisolated let events: AsyncStream<TranscriptEvent>
    private let eventSink: AsyncStream<TranscriptEvent>.Continuation

    private let provider: any EngineProvider
    private let settings: AppSettings
    private let audioSink: (any SessionAudioSink)?

    private var phase: SessionPhase = .idle
    private var started = false
    private var engines: EngineSet?
    private var segmenter: UtteranceSegmenter

    private var transcript: [Utterance] = []
    private var open: Utterance?
    private var openEmitted = false

    private var jobs: AsyncStream<CorrectionJob>.Continuation?
    private var worker: Task<Void, Never>?
    /// Translation runs on its own queue so it never delays the next correction.
    private var translationJobs: AsyncStream<TranslationJob>.Continuation?
    private var translationWorker: Task<Void, Never>?
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<[Utterance], Never>] = []
    private var shownNotices: Set<String> = []

    /// Clips shorter than this are not sent to the speaker labeler.
    private let minLabelSamples = AudioSpec.samples(forMilliseconds: 600)

    private struct CorrectionJob: Sendable {
        let id: UUID
        let samples: [Float]
        let hint: String
        let speechMs: Int
        /// The voiced part (±0.1 s) within `samples`, for the speaker embedding.
        let voiced: Range<Int>
    }

    private struct TranslationJob: Sendable {
        let id: UUID
        let text: String
    }

    /// `segmentation` lets evaluations try other thresholds; settings still set the pause and length.
    public init(
        provider: any EngineProvider, settings: AppSettings, audioSink: (any SessionAudioSink)? = nil,
        segmentation: SegmenterConfig = SegmenterConfig()
    ) {
        self.provider = provider
        self.settings = settings
        self.audioSink = audioSink
        var config = segmentation
        config.silenceMs = settings.silenceMs
        config.maxUtteranceMs = max(5, settings.maxUtteranceSeconds) * 1000
        segmenter = UtteranceSegmenter(config: config)
        (events, eventSink) = AsyncStream.makeStream(of: TranscriptEvent.self)
    }

    public var currentPhase: SessionPhase { phase }

    public var utterances: [Utterance] { transcript }

    /// Audio time ingested so far.
    public var elapsedMs: Int { AudioSpec.milliseconds(forSamples: segmenter.position) }

    // MARK: - Lifecycle

    public func start() async throws {
        guard !started else { return }
        started = true
        setPhase(.preparing)

        var created: EngineSet?
        do {
            let set = try await provider.makeEngines(for: settings)
            created = set
            try await set.streaming.prepare()
            try await set.corrector?.prepare()

            var fallback = set.fallbackCorrector
            if let candidate = fallback {
                do {
                    try await candidate.prepare()
                } catch {
                    fallback = nil
                    notice("本机备用纠错不可用：\(error.localizedDescription)")
                }
            }

            var labeler = set.speakerLabeler
            if let candidate = labeler {
                do {
                    try await candidate.prepare(expectedSpeakers: settings.expectedSpeakers)
                } catch {
                    labeler = nil
                    notice("说话人标注不可用：\(error.localizedDescription)")
                }
            }

            var translator = set.translator
            if let candidate = translator {
                do {
                    try await candidate.prepare()
                } catch {
                    translator = nil
                    notice("实时翻译不可用：\(error.localizedDescription)")
                }
            }

            guard phase == .preparing else { throw CancellationError() }

            let ready = EngineSet(
                streaming: set.streaming,
                corrector: set.corrector,
                fallbackCorrector: fallback,
                speakerLabeler: labeler,
                translator: translator
            )
            engines = ready
            startWorkers()
            eventSink.yield(.engines(EngineInfo(
                streaming: ready.streaming.providerID,
                corrector: ready.corrector?.providerID,
                fallbackCorrector: ready.fallbackCorrector?.providerID,
                speakerLabeling: ready.speakerLabeler != nil,
                translator: ready.translator?.providerID
            )))
            setPhase(.listening)
        } catch {
            if let created {
                await Self.shutdown(created)
            }
            engines = nil
            audioSink?.close()
            setPhase(.idle)
            eventSink.finish()
            throw error
        }
    }

    public func ingest(_ samples: [Float]) async {
        guard phase == .listening, let engines, !samples.isEmpty else { return }
        audioSink?.append(samples)
        let closedByVAD = segmenter.push(samples)

        let update: StreamingUpdate
        do {
            update = try await engines.streaming.accept(samples)
        } catch {
            notice("实时识别出错：\(error.localizedDescription)")
            update = StreamingUpdate(text: open?.partial ?? "")
        }
        if !closedByVAD.isEmpty {
            // Already cut from the segmenter: queue them even if a pause/stop began meanwhile.
            // The streaming text belongs to the sentence(s) just closed.
            for segment in closedByVAD {
                await closeSentence(segment)
            }
            return
        }
        guard phase == .listening else { return }

        updatePartial(update.text)
        if open == nil && !segmenter.hasSpeech {
            // Neither the VAD nor the recognizer hears anyone: drop old leading silence,
            // keeping enough to cover the recognizer's latency.
            segmenter.discardIdle(keepingMs: 2_000)
        }
        if update.isEndpoint {
            if TextFilter.isMeaningful(update.text) {
                // Otherwise keep listening: the endpoint stays raised until new words are
                // decoded, so the sentence closes as soon as the VAD hears the pause too.
                if segmenter.acceptsEndpoint {
                    await closeSentence(segmenter.cut())
                }
            } else if !segmenter.hasSpeech {
                // Silence-only endpoint (sherpa rule 1): just restart the decoder.
                _ = await engines.streaming.finishUtterance()
            }
            // Otherwise someone is talking and the decoder hasn't caught up yet: never chop
            // a sentence that just started (its delayed silence endpoint lands here).
        }
    }

    /// Closes the open sentence so a pause never splits one sentence in two.
    public func pause() async {
        guard phase == .listening else { return }
        setPhase(.paused)
        await closeSentence(segmenter.cut())
    }

    public func resume() {
        guard phase == .paused else { return }
        setPhase(.listening)
    }

    /// Flushes the open sentence, waits for all corrections, releases engines.
    /// Idempotent: a second call waits for the same drain.
    @discardableResult
    public func stop() async -> [Utterance] {
        if isStopping {
            return await withCheckedContinuation { stopWaiters.append($0) }
        }
        guard phase == .listening || phase == .paused || phase == .preparing else { return transcript }
        if phase == .preparing {
            // `start()` notices the phase change and cleans up.
            setPhase(.finishing)
            return transcript
        }
        isStopping = true
        setPhase(.finishing)
        let result = await drainAndShutdown()
        isStopping = false
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume(returning: result) }
        return result
    }

    private func drainAndShutdown() async -> [Utterance] {
        await closeSentence(segmenter.cut())
        jobs?.finish()
        await worker?.value
        worker = nil
        jobs = nil
        translationJobs?.finish()
        await translationWorker?.value
        translationWorker = nil
        translationJobs = nil

        if let engines {
            await Self.shutdown(engines)
        }
        engines = nil
        audioSink?.close()
        setPhase(.idle)
        eventSink.finish()
        return transcript
    }

    private static func shutdown(_ set: EngineSet) async {
        await set.streaming.shutdown()
        await set.corrector?.shutdown()
        await set.fallbackCorrector?.shutdown()
        await set.speakerLabeler?.shutdown()
        await set.translator?.shutdown()
    }

    // MARK: - Sentences

    private func updatePartial(_ text: String) {
        let trimmed = TextFilter.normalizeCase(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let engines else { return }
        if var current = open {
            guard current.partial != trimmed else { return }
            current.partial = trimmed
            open = current
        } else {
            guard TextFilter.isMeaningful(trimmed) else { return }
            let start = segmenter.openSpeechStart ?? segmenter.position
            open = Utterance(
                startMs: AudioSpec.milliseconds(forSamples: start),
                partial: trimmed,
                provider: engines.streaming.providerID
            )
        }
        if let current = open, TextFilter.isMeaningful(current.partial) || openEmitted {
            upsert(current)
            openEmitted = true
        }
    }

    private func closeSentence(_ segment: Segment?) async {
        guard let engines, jobs != nil else { return }
        let finished = await engines.streaming.finishUtterance()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var utterance = open ?? Utterance(startMs: 0, provider: engines.streaming.providerID)
        let wasEmitted = openEmitted
        open = nil
        openEmitted = false

        let hint = finished.isEmpty ? utterance.partial : TextFilter.normalizeCase(finished)
        guard let segment,
              TextFilter.isMeaningful(hint)
                || segment.speechMs >= segmenter.config.minSpeechMs
        else {
            if wasEmitted { remove(utterance.id) }
            return
        }

        utterance.startMs = AudioSpec.milliseconds(forSamples: segment.speechStartSample)
        utterance.endMs = AudioSpec.milliseconds(forSamples: segment.speechEndSample)
        utterance.partial = hint
        utterance.status = .pendingCorrection
        upsert(utterance)
        // Segments are contiguous, so they can start with seconds of silence, music or the
        // tail of someone else; the embedding hears only the speech. Measured on two AMI
        // meetings (CAM++): speaker accuracy 57% / 87% with the whole segment, 95% / 90% voiced.
        let pad = AudioSpec.samples(forMilliseconds: 100)
        let from = min(segment.samples.count, max(0, segment.speechStartSample - segment.startSample - pad))
        let to = max(from, min(segment.samples.count, segment.speechEndSample - segment.startSample + pad))
        jobs?.yield(CorrectionJob(id: utterance.id, samples: segment.samples, hint: hint, speechMs: segment.speechMs, voiced: from..<to))
    }

    // MARK: - Correction worker

    private func startWorkers() {
        let (stream, continuation) = AsyncStream.makeStream(of: CorrectionJob.self)
        jobs = continuation
        worker = Task { [weak self] in
            for await job in stream {
                await self?.process(job)
            }
        }
        let (translations, translationContinuation) = AsyncStream.makeStream(of: TranslationJob.self)
        translationJobs = translationContinuation
        translationWorker = Task { [weak self] in
            for await job in translations {
                await self?.translate(job)
            }
        }
    }

    private func translate(_ job: TranslationJob) async {
        guard let translator = engines?.translator,
              let direction = settings.translation.target.direction(for: job.text)
        else { return }
        do {
            let text = try await translator.translate(job.text, from: direction.source, to: direction.target)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, var utterance = transcript.first(where: { $0.id == job.id }) else { return }
            utterance.translation = text
            upsert(utterance)
        } catch {
            notice("翻译失败：\(error.localizedDescription)")
        }
    }

    private func process(_ job: CorrectionJob) async {
        guard let engines else { return }
        var text = job.hint
        var providerID = engines.streaming.providerID
        var failure: String?
        let input = AudioSpec.normalizedForRecognition(job.samples)

        if let corrector = engines.corrector {
            do {
                text = try await corrector.correct(input, hint: job.hint)
                providerID = corrector.providerID
            } catch {
                if let fallback = engines.fallbackCorrector {
                    do {
                        text = try await fallback.correct(input, hint: job.hint)
                        providerID = fallback.providerID
                        notice("云端纠错失败（\(error.localizedDescription)），已回退本机纠错")
                    } catch let fallbackError {
                        failure = fallbackError.localizedDescription
                    }
                } else {
                    failure = error.localizedDescription
                }
            }
        }
        text = TextFilter.normalizeCase(TextFilter.normalizePunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let heard = failure == nil ? TextFilter.isMeaningful(text) : TextFilter.isMeaningful(job.hint)

        // Only real speech is clustered: a click that recognizes as nothing must not
        // occupy "说话人 1".
        var speaker: Int?
        if heard, let labeler = engines.speakerLabeler {
            // The VAD may have missed quiet speech entirely; then the whole segment is all there is.
            let voiced = job.voiced.count >= minLabelSamples ? Array(job.samples[job.voiced]) : job.samples
            if voiced.count >= minLabelSamples {
                // How much the speaker said decides whether the clip may start a new speaker.
                // The VAD's count of loud frames badly undercounts distant or quiet voices (and
                // system audio), which kept new speakers from ever being created.
                let spokenMs = max(job.speechMs, AudioSpec.milliseconds(forSamples: voiced.count) - 200)
                speaker = try? await labeler.assign(voiced, speechMs: spokenMs)
            }
        }

        guard var utterance = transcript.first(where: { $0.id == job.id }) else { return }
        guard heard else {
            remove(job.id)
            return
        }
        if let failure {
            utterance.status = .failed
            utterance.errorMessage = failure
        } else {
            utterance.finalText = text
            utterance.status = .final
            utterance.provider = providerID
            utterance.errorMessage = nil
        }
        utterance.speakerIndex = speaker
        upsert(utterance)
        if engines.translator != nil, utterance.status == .final {
            translationJobs?.yield(TranslationJob(id: utterance.id, text: utterance.displayText))
        }
    }

    // MARK: - Events

    private func upsert(_ utterance: Utterance) {
        if let index = transcript.firstIndex(where: { $0.id == utterance.id }) {
            transcript[index] = utterance
        } else {
            transcript.append(utterance)
        }
        eventSink.yield(.upsert(utterance))
    }

    private func remove(_ id: UUID) {
        transcript.removeAll { $0.id == id }
        eventSink.yield(.remove(id))
    }

    private func setPhase(_ next: SessionPhase) {
        phase = next
        eventSink.yield(.phase(next))
    }

    private func notice(_ message: String) {
        guard shownNotices.insert(message).inserted else { return }
        eventSink.yield(.notice(message))
    }
}
