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
    /// Domain terms written as same-sounding words are put back, live and final.
    private let lexicon: TermLexicon
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

    private var waiting: [Float] = []
    private static let maxWaitingSamples = AudioSpec.samples(forMilliseconds: 60_000)

    /// The open sentence's text as the recognizer wrote it; what is shown may start with an
    /// early correction instead (`interim`).
    private var live = ""
    /// A long sentence still being spoken gets its first part corrected early, every few
    /// seconds, so corrected text never waits for a 15–20 s monologue sentence to end. It is
    /// shown in place of that much live text (`liveCount` characters).
    private var interim: (text: String, liveCount: Int)?
    private var interimRunning = false
    private let earlyCorrections: Bool
    private var nextInterimAt = 0
    /// Corrections queued or running; early ones wait for these.
    private var pendingCorrections = 0
    static let interimAfterMs = 6_000
    static let interimEveryMs = 4_000

    /// Clips shorter than this are not sent to the speaker labeler.
    private let minLabelSamples = AudioSpec.samples(forMilliseconds: 600)

    /// Speaker changes inside the open sentence (only when speakers are labeled; nil = off).
    private var changeDetector: SpeakerChangeDetector?
    /// Speech start of the sentence the detector is following, and where its next window ends.
    private var changeSentence: Int?
    private var nextChangeWindowEnd = 0
    /// Where the streaming recognizer's current sentence began (its token times count from here).
    private var streamStart = 0

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
        segmentation: SegmenterConfig = SegmenterConfig(),
        speakerChanges: SpeakerChangeDetector? = SpeakerChangeDetector(),
        earlyCorrections: Bool = true
    ) {
        self.provider = provider
        self.settings = settings
        self.audioSink = audioSink
        changeDetector = speakerChanges
        self.earlyCorrections = earlyCorrections
        lexicon = settings.termLexicon
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
            // All models load at once: the slowest (an LLM corrector, ~2 s) sets the wait,
            // not their sum (~3.5 s with X-ASR + Fun-ASR-Nano).
            let expected = settings.expectedSpeakers
            async let streamingError = Self.attempt { try await set.streaming.prepare() }
            async let correctorError = Self.attempt { try await set.corrector?.prepare() }
            async let fallbackError = Self.attempt { try await set.fallbackCorrector?.prepare() }
            async let labelerError = Self.attempt { try await set.speakerLabeler?.prepare(expectedSpeakers: expected) }
            async let translatorError = Self.attempt { try await set.translator?.prepare() }
            async let voiceError = Self.attempt { try await set.voiceDetector?.prepare() }
            let failures = await (streamingError, correctorError, fallbackError, labelerError, translatorError, voiceError)
            if let error = failures.0 ?? failures.1 { throw error }

            var fallback = set.fallbackCorrector
            if let error = failures.2 {
                fallback = nil
                notice("本机备用纠错不可用：\(error.localizedDescription)")
            }
            var labeler = set.speakerLabeler
            if let error = failures.3 {
                labeler = nil
                notice("说话人标注不可用：\(error.localizedDescription)")
            }
            var translator = set.translator
            if let error = failures.4 {
                translator = nil
                notice("实时翻译不可用：\(error.localizedDescription)")
            }
            // Without it the energy VAD still segments, as before.
            let voiceDetector = failures.5 == nil ? set.voiceDetector : nil

            guard phase == .preparing else { throw CancellationError() }

            let ready = EngineSet(
                streaming: set.streaming,
                corrector: set.corrector,
                fallbackCorrector: fallback,
                speakerLabeler: labeler,
                translator: translator,
                voiceDetector: voiceDetector
            )
            engines = ready
            if voiceDetector != nil { segmenter.useVoiceModel() }
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

    private static func attempt(_ prepare: @Sendable () async throws -> Void) async -> Error? {
        do {
            try await prepare()
            return nil
        } catch {
            return error
        }
    }

    /// Recording starts before the models are ready: audio from that time waits here and is
    /// recognized first once they are, so nothing said right after pressing record is lost.
    public func ingest(_ samples: [Float]) async {
        if phase == .preparing {
            if waiting.count < Self.maxWaitingSamples { waiting += samples }
            return
        }
        guard phase == .listening, engines != nil, !samples.isEmpty else { return }
        if !waiting.isEmpty {
            let backlog = waiting
            waiting = []
            for start in stride(from: 0, to: backlog.count, by: 1600) {
                await ingestChunk(Array(backlog[start..<min(start + 1600, backlog.count)]))
            }
        }
        await ingestChunk(samples)
    }

    private func ingestChunk(_ samples: [Float]) async {
        guard phase == .listening, let engines, !samples.isEmpty else { return }
        audioSink?.append(samples)
        let voice = await engines.voiceDetector?.detect(samples) ?? []
        // The recognizer first, so a length cut in this chunk knows its latest clause marks.
        let update: StreamingUpdate
        do {
            update = try await engines.streaming.accept(samples)
        } catch {
            notice("实时识别出错：\(error.localizedDescription)")
            update = StreamingUpdate(text: live)
        }
        segmenter.noteClauseEnds(update.clauseEnds.map { streamStart + Int($0 * Double(AudioSpec.sampleRate)) })
        let closedByVAD = segmenter.push(samples, voice: voice)
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
        if let segment = await speakerChange() {
            await closeSentence(segment)
            return
        }
        startInterimIfDue(heardUntil: update.heardUntil)
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
                streamStart = segmenter.position
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
        await set.voiceDetector?.shutdown()
    }

    // MARK: - Sentences

    private func updatePartial(_ text: String) {
        let trimmed = lexicon.correct(TextFilter.tightenChineseSpacing(TextFilter.normalizeCase(text.trimmingCharacters(in: .whitespacesAndNewlines))))
        guard let engines else { return }
        live = trimmed
        let shown = display(trimmed)
        if var current = open {
            guard current.partial != shown else { return }
            current.partial = shown
            open = current
        } else {
            guard TextFilter.isMeaningful(trimmed) else { return }
            let start = segmenter.openSpeechStart ?? segmenter.position
            open = Utterance(
                startMs: AudioSpec.milliseconds(forSamples: start),
                partial: shown,
                provider: engines.streaming.providerID
            )
        }
        if let current = open, TextFilter.isMeaningful(current.partial) || openEmitted {
            upsert(current)
            openEmitted = true
        }
    }

    /// The early correction, then the live text heard since.
    private func display(_ live: String) -> String {
        guard let interim, live.count >= interim.liveCount else { return live }
        return TextFilter.joinCorrected(interim.text, live: String(live.dropFirst(interim.liveCount)))
    }

    /// Corrects what has been said of a long open sentence, when the corrector is idle.
    private func startInterimIfDue(heardUntil: Double?) {
        guard earlyCorrections, let corrector = engines?.corrector, let id = open?.id, !interimRunning, pendingCorrections == 0,
              let heardUntil, segmenter.hasSpeech, let speechStart = segmenter.openSpeechStart,
              segmenter.position - speechStart >= AudioSpec.samples(forMilliseconds: Self.interimAfterMs),
              segmenter.position >= nextInterimAt
        else { return }
        // Up to the latest word the live text has (and a little past it, for its sound).
        let cover = streamStart + Int(heardUntil * Double(AudioSpec.sampleRate)) + AudioSpec.samples(forMilliseconds: 200)
        let clip = segmenter.samples(from: segmenter.openStart).prefix(max(0, cover - segmenter.openStart))
        guard clip.count >= AudioSpec.samples(forMilliseconds: 2_000) else { return }
        interimRunning = true
        nextInterimAt = segmenter.position + AudioSpec.samples(forMilliseconds: Self.interimEveryMs)
        let liveCount = live.count
        let hint = live
        let input = AudioSpec.normalizedForRecognition(Array(clip))
        Task { [weak self] in
            let text = try? await corrector.preview(input, hint: hint)
            await self?.applyInterim(text, for: id, liveCount: liveCount)
        }
    }

    private func applyInterim(_ text: String?, for id: UUID, liveCount: Int) {
        interimRunning = false
        guard let text, var current = open, current.id == id else { return }
        let cleaned = lexicon.correct(TextFilter.tightenChineseSpacing(
            TextFilter.normalizeCase(TextFilter.normalizePunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        ))
        guard TextFilter.isMeaningful(cleaned) else { return }
        interim = (cleaned, liveCount)
        current.partial = display(live)
        open = current
        upsert(current)
    }

    /// Checks the open sentence, one window per hop, for another voice taking over without a
    /// pause; returns its first part, cut where the change happened.
    private func speakerChange() async -> Segment? {
        guard var detector = changeDetector, let labeler = engines?.speakerLabeler, segmenter.hasSpeech,
              let speechStart = segmenter.openSpeechStart
        else { return nil }
        let window = AudioSpec.samples(forMilliseconds: detector.windowMs)
        if changeSentence != speechStart {
            changeSentence = speechStart
            detector.start(at: speechStart)
            nextChangeWindowEnd = speechStart + window
        }
        defer { changeDetector = detector }
        guard segmenter.position >= nextChangeWindowEnd else { return nil }
        let windowStart = nextChangeWindowEnd - window
        nextChangeWindowEnd += AudioSpec.samples(forMilliseconds: detector.hopMs)
        let clip = segmenter.samples(from: windowStart).prefix(window)
        guard clip.count == window, let embedding = await labeler.embed(Array(clip)) else { return nil }
        // The actor may have run other work during the await; the window still belongs to this sentence.
        guard changeSentence == segmenter.openSpeechStart,
              let boundary = detector.observe(embedding, windowStart: windowStart)
        else { return nil }
        return segmenter.cutInSpeech(near: boundary, reason: .speakerChange)
    }

    private func closeSentence(_ segment: Segment?) async {
        guard let engines, jobs != nil else { return }
        // A length or speaker cut lies in the past: the recognizer has already heard the start
        // of the next sentence. Keep only the text before the cut (token times lag the audio a
        // little) and feed the rest of the audio again for the next sentence.
        let pastCut = segment?.reason.isInSpeech ?? false
        let finished: String
        if pastCut, let segment {
            let seconds = Double(segment.endSample - streamStart) / Double(AudioSpec.sampleRate) + 0.15
            finished = await engines.streaming.finishUtterance(keepingUntil: seconds)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            streamStart = segment.endSample
        } else {
            finished = await engines.streaming.finishUtterance()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            streamStart = segmenter.position
        }
        queue(segment, finished: finished, provider: engines.streaming.providerID)
        if pastCut, let segment {
            await refeed(after: segment.endSample)
        }
    }

    /// Turns the open sentence into a correction job (or drops it when nothing was said).
    private func queue(_ segment: Segment?, finished: String, provider: String) {
        var utterance = open ?? Utterance(startMs: 0, provider: provider)
        let wasEmitted = openEmitted
        let early = interim
        open = nil
        openEmitted = false
        interim = nil
        live = ""
        nextInterimAt = 0

        let hint = finished.isEmpty ? utterance.partial : lexicon.correct(TextFilter.tightenChineseSpacing(TextFilter.normalizeCase(finished)))
        guard let segment,
              TextFilter.isMeaningful(hint)
                || segment.speechMs >= segmenter.config.minSpeechMs
        else {
            if wasEmitted { remove(utterance.id) }
            return
        }

        utterance.startMs = AudioSpec.milliseconds(forSamples: segment.speechStartSample)
        utterance.endMs = AudioSpec.milliseconds(forSamples: segment.speechEndSample)
        // Until the final correction lands, keep showing the early one where it still applies.
        if let early, hint.count >= early.liveCount {
            utterance.partial = TextFilter.joinCorrected(early.text, live: String(hint.dropFirst(early.liveCount)))
        } else {
            utterance.partial = hint
        }
        utterance.status = .pendingCorrection
        upsert(utterance)
        // Segments are contiguous, so they can start with seconds of silence, music or the
        // tail of someone else; the embedding hears only the speech. Measured on two AMI
        // meetings (CAM++): speaker accuracy 57% / 87% with the whole segment, 95% / 90% voiced.
        let pad = AudioSpec.samples(forMilliseconds: 100)
        let from = min(segment.samples.count, max(0, segment.speechStartSample - segment.startSample - pad))
        let to = max(from, min(segment.samples.count, segment.speechEndSample - segment.startSample + pad))
        pendingCorrections += 1
        jobs?.yield(CorrectionJob(id: utterance.id, samples: segment.samples, hint: hint, speechMs: segment.speechMs, voiced: from..<to))
    }

    /// The audio after a cut in the past, decoded again as the start of the next sentence.
    private func refeed(after cut: Int) async {
        guard phase == .listening || phase == .paused, let engines else { return }
        let rest = segmenter.samples(from: cut)
        guard !rest.isEmpty, let update = try? await engines.streaming.accept(rest) else { return }
        updatePartial(update.text)
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
            guard !text.isEmpty, var utterance = transcript.last(where: { $0.id == job.id }) else { return }
            utterance.translation = text
            upsert(utterance)
        } catch {
            notice("翻译失败：\(error.localizedDescription)")
        }
    }

    private func process(_ job: CorrectionJob) async {
        defer { pendingCorrections -= 1 }
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
        text = lexicon.correct(TextFilter.tightenChineseSpacing(
            TextFilter.normalizeCase(TextFilter.normalizePunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        ))
        // Some models start a clip that begins mid-pause with "。".
        text = String(text.drop { "。，、；：？！.,;:?!".contains($0) || $0.isWhitespace })
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

        guard var utterance = transcript.last(where: { $0.id == job.id }) else { return }
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

    /// Updates hit the newest sentences (partials at ~10 Hz), so search from the end.
    private func upsert(_ utterance: Utterance) {
        if let index = transcript.lastIndex(where: { $0.id == utterance.id }) {
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
