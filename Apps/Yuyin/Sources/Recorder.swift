import Foundation
import Observation
import YuyinCore
import YuyinLocal
#if os(iOS)
import UIKit
#endif

/// Drives one recording at a time: capture → session → saved meeting.
@Observable
@MainActor
final class Recorder {
    private(set) var phase: SessionPhase = .idle
    /// Live transcript with the user's speaker edits applied.
    private(set) var utterances: [Utterance] = []
    private(set) var speakers = SpeakerBook()
    private(set) var engineInfo: EngineInfo?
    private(set) var level: Float = 0
    private(set) var elapsedMs = 0
    private(set) var meetingID: UUID?
    private(set) var source: AudioSourceChoice = .microphone
    /// The meeting just saved by `stop()`, shown as a completion card until dismissed.
    private(set) var completedMeetingID: UUID?
    var notice: String?
    var errorMessage: String?

    private let library: MeetingLibrary
    private var session: TranscriptionSession?
    private var capture: AudioCapture?
    private var pump: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var autosave: Task<Void, Never>?
    private var draft: Meeting?
    private var rawUtterances: [Utterance] = []
    /// Serializes start / pause / resume / stop (buttons can be tapped faster than events arrive).
    private var transitioning = false

    init(library: MeetingLibrary) {
        self.library = library
    }

    var isActive: Bool { session != nil || demoActive }

    private var demoActive = false

    #if DEBUG
    /// UI preview data (`-YuyinDemo live|done`), used for screenshots and layout checks.
    func loadDemo(_ mode: String, library: MeetingLibrary) async {
        var a = Utterance(startMs: 3_200, endMs: 6_100, partial: "我们先过一下这周的进度",
                          finalText: "我们先过一下这周的进度。", status: .final, provider: "ane-sensevoice", speakerIndex: 0)
        a.translation = "Let's go over this week's progress first."
        let b = Utterance(startMs: 6_800, partial: "好的，设计稿周三已经交付了，接下来", status: .partial, provider: "sherpa-zipformer")
        var extra: [Utterance] = []
        let lines = ["我们先过一下这周的进度。", "设计稿周三已经交付了，开发这边预计下周二提测。", "测试环境的数据库还要再扩容一下。",
                     "好的，那我们周五前把方案定下来。", "Let's sync again on Friday morning.", "没问题，我会整理一份会议纪要发到群里。"]
        for (i, line) in lines.enumerated() {
            var u = Utterance(startMs: 10_000 + i * 4_000, endMs: 13_000 + i * 4_000, partial: line, finalText: line,
                              status: .final, provider: "sherpa-funasr-nano", speakerIndex: i % 2)
            u.translation = i == 4 ? "我们周五上午再同步一下。" : nil
            extra.append(u)
        }
        speakers = SpeakerBook()
        speakers.rename(0, to: "张三")
        rawUtterances = [a] + extra + [b]
        utterances = rawUtterances.map(speakers.resolve)
        engineInfo = EngineInfo(streaming: "sherpa-zipformer", corrector: "ane-sensevoice", speakerLabeling: true, translator: "apple-translation")
        elapsedMs = 6_900
        level = 0.4
        if mode == "done" {
            var meeting = Meeting(title: "周会 10月11日", utterances: [a], speakerNames: [0: "张三"], durationMs: 65_000)
            meeting.utterances[0].speakerIndex = 0
            await library.save(meeting)
            completedMeetingID = meeting.id
        } else {
            demoActive = true
            phase = .listening
        }
    }
    #endif

    /// Latest sentences for the compact live panel.
    func latest(_ count: Int) -> [Utterance] {
        Array(utterances.suffix(count))
    }

    var speakerIndices: [Int] { speakers.speakers(in: utterances) }

    // MARK: - Lifecycle

    func start(preferences: Preferences, models: ModelManager) async {
        guard session == nil, !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        errorMessage = nil
        notice = nil
        completedMeetingID = nil

        let settings = preferences.settings
        if settings.audioSource.usesMicrophone {
            guard await AudioCapture.requestMicrophonePermission() else {
                errorMessage = ASRError.permissionDenied("麦克风").localizedDescription
                return
            }
        }
        if settings.audioSource.usesSystemAudio && !AudioCapture.supportsSystemAudio {
            errorMessage = AudioCapture.CaptureError.systemAudioUnsupported.localizedDescription
            return
        }

        let id = UUID()
        let sink: WAVFileWriter
        do {
            sink = try WAVFileWriter(url: library.store.audioURL(for: id))
        } catch {
            errorMessage = "无法创建录音文件：\(error.localizedDescription)"
            return
        }

        let session = TranscriptionSession(
            provider: AppEngineProvider(local: models.engines, apiKey: preferences.apiKey),
            settings: settings,
            audioSink: sink
        )
        self.session = session
        utterances = []
        rawUtterances = []
        speakers = SpeakerBook()
        engineInfo = nil
        elapsedMs = 0
        meetingID = id
        source = settings.audioSource
        draft = Meeting(id: id, title: Meeting.defaultTitle(for: Date()), mode: settings.mode, isRecording: true)
        events = Task { [weak self] in
            for await event in session.events {
                self?.apply(event)
            }
        }

        do {
            try await session.start()
        } catch {
            errorMessage = error.localizedDescription
            await events?.value
            try? await library.store.delete(id)
            reset()
            return
        }

        // Phase normally follows session events; set it now so the UI never lags the session.
        phase = .listening
        if let draft { await library.save(draft) }
        do {
            try startCapture(settings)
        } catch {
            errorMessage = error.localizedDescription
            transitioning = false
            await stop()
            return
        }
        setIdleTimerDisabled(true)
    }

    func pause() async {
        guard phase == .listening, let session, !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        await stopCapture()
        await session.pause()
    }

    func resume(preferences: Preferences) async {
        guard phase == .paused, let session, !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        await session.resume()
        do {
            try startCapture(preferences.settings)
        } catch {
            errorMessage = error.localizedDescription
            await session.pause()
        }
    }

    /// Returns the saved meeting's id, or nil when nothing was recognized.
    @discardableResult
    func stop() async -> UUID? {
        guard let session, !transitioning else { return nil }
        transitioning = true
        defer { transitioning = false }
        await stopCapture()
        let transcript = await session.stop()
        await events?.value
        // An autosave already writing must land before the final save, not after it.
        autosave?.cancel()
        await autosave?.value
        setIdleTimerDisabled(false)

        var savedID: UUID?
        if var meeting = draft {
            meeting.utterances = transcript.map(speakers.resolve)
            meeting.speakerNames = speakers.names
            meeting.durationMs = elapsedMs
            meeting.engines = engineInfo.map(EngineNames.summary)
            meeting.isRecording = false
            if transcript.isEmpty {
                await library.delete(meeting.id)
                notice = "没有识别到语音，本次录音未保存"
            } else {
                await library.save(meeting)
                savedID = meeting.id
            }
        }
        reset()
        completedMeetingID = savedID
        return savedID
    }

    func dismissCompletion() {
        completedMeetingID = nil
    }

    // MARK: - Speakers

    /// Naming a speaker with another speaker's name merges them.
    func renameSpeaker(_ index: Int, to name: String) {
        speakers.rename(index, to: name)
        refreshUtterances()
        scheduleAutosave()
    }

    /// Moves one sentence to another speaker; `nil` creates a new speaker.
    func reassign(_ utteranceID: UUID, to index: Int?) {
        let target = index ?? speakers.nextIndex(after: rawUtterances)
        speakers.reassign(utteranceID, to: target)
        refreshUtterances()
        scheduleAutosave()
    }

    func label(for index: Int?) -> String? {
        speakers.label(for: index)
    }

    // MARK: - Private

    private func startCapture(_ settings: AppSettings) throws {
        let capture = AudioCapture()
        capture.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleCaptureEvent(event) }
        }
        let stream = try capture.start(source: settings.audioSource, appBundleID: settings.audioAppBundleID)
        self.capture = capture
        guard let session else { return }
        let watchSilence = settings.audioSource.usesSystemAudio
        // One consumer, in order: the session contract requires sequential ingest.
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            var lastPublish = Date.distantPast
            var silentSince: Date?
            var warned = false
            for await chunk in stream {
                await session.ingest(chunk.samples)
                let now = Date()
                if watchSilence && !warned {
                    // Exact digital silence for a while usually means the permission was denied.
                    if chunk.peak == 0 {
                        let since = silentSince ?? now
                        silentSince = since
                        if now.timeIntervalSince(since) > 8 {
                            warned = true
                            await self?.warnNoSystemAudio()
                        }
                    } else {
                        silentSince = nil
                    }
                }
                if now.timeIntervalSince(lastPublish) > 0.08 {
                    lastPublish = now
                    let elapsed = await session.elapsedMs
                    await self?.publish(level: chunk.peak, elapsedMs: elapsed)
                }
            }
        }
    }

    private func stopCapture() async {
        capture?.stop()
        capture = nil
        await pump?.value
        pump = nil
        level = 0
    }

    private func publish(level: Float, elapsedMs: Int) {
        self.level = min(1, level * 3)
        self.elapsedMs = elapsedMs
    }

    private func warnNoSystemAudio() {
        notice = "没有收到系统声音：请确认会议或网页正在播放，并在 系统设置 → 隐私与安全性 → 屏幕与系统录音 中允许「语音转写」录制系统音频"
    }

    private func handleCaptureEvent(_ event: AudioCapture.Event) {
        switch event {
        case .interrupted:
            guard phase == .listening else { return }
            notice = "录音被系统中断，已暂停"
            Task { await pause() }
        case .interruptionEnded:
            break
        }
    }

    private func apply(_ event: TranscriptEvent) {
        switch event {
        case .phase(let next):
            phase = next
        case .engines(let info):
            engineInfo = info
            draft?.engines = EngineNames.summary(info)
        case .upsert(let utterance):
            if let index = rawUtterances.firstIndex(where: { $0.id == utterance.id }) {
                rawUtterances[index] = utterance
            } else {
                rawUtterances.append(utterance)
            }
            let resolved = speakers.resolve(utterance)
            if let index = utterances.firstIndex(where: { $0.id == utterance.id }) {
                utterances[index] = resolved
            } else {
                utterances.append(resolved)
            }
            if utterance.status == .final || utterance.status == .failed {
                scheduleAutosave()
            }
        case .remove(let id):
            rawUtterances.removeAll { $0.id == id }
            utterances.removeAll { $0.id == id }
        case .notice(let message):
            notice = message
        }
    }

    private func refreshUtterances() {
        utterances = rawUtterances.map(speakers.resolve)
    }

    /// Keeps the on-disk meeting current so a crash loses at most a couple of seconds.
    private func scheduleAutosave() {
        guard draft != nil else { return }
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, var draft = self.draft else { return }
            draft.utterances = self.utterances.filter { $0.status == .final || $0.status == .failed }
            draft.speakerNames = self.speakers.names
            draft.durationMs = self.elapsedMs
            await self.library.save(draft)
        }
    }

    private func reset() {
        session = nil
        events = nil
        autosave = nil
        draft = nil
        meetingID = nil
        phase = .idle
        level = 0
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        // No background-audio mode: keep the screen on while recording.
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
