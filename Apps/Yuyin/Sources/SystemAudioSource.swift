#if os(macOS)
import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// Records what other apps play (Tencent Meeting, Feishu, Zoom, browsers…) with a
/// Core Audio process tap. Needs the "System Audio Recording" privacy permission,
/// which macOS asks for on first use (`NSAudioCaptureUsageDescription`).
@available(macOS 14.2, *)
final class SystemAudioSource: @unchecked Sendable {
    enum Target {
        /// Everything except Yuyin itself.
        case allApps
        /// One app, including its helper processes (e.g. `com.google.Chrome.helper`).
        case app(bundleID: String)
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.yuyin.capture.system", qos: .userInitiated)

    func start(target: Target, onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let description: CATapDescription
        switch target {
        case .allApps:
            let own = (try? Self.processObject(pid: getpid())).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        case .app(let bundleID):
            let processes = Self.processObjects(matching: bundleID)
            guard !processes.isEmpty else {
                throw AudioCapture.CaptureError.appNotPlaying(Self.appName(bundleID))
            }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "Yuyin"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "创建音频采集")

        var format = try tapFormat()
        guard let input = AVAudioFormat(streamDescription: &format), let resampler = PCMResampler(from: input) else {
            throw AudioCapture.CaptureError.coreAudio("音频格式", -1)
        }

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Yuyin System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "创建聚合设备")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input, bufferListNoCopy: inputData, deallocator: nil),
                  let samples = resampler.convert(buffer)
            else { return }
            onSamples(samples)
        }, "注册回调")
        try check(AudioDeviceStart(aggregateID, procID), "开始采集")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        queue.sync {}
    }

    deinit { stop() }

    // MARK: - Core Audio helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            stop()
            throw AudioCapture.CaptureError.coreAudio(step, status)
        }
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = Self.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "读取格式")
        return format
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }

    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else {
            throw AudioCapture.CaptureError.coreAudio("查找进程", status)
        }
        return object
    }

    /// Audio process objects whose bundle ID is `bundleID` or one of its helpers.
    static func processObjects(matching bundleID: String) -> [AudioObjectID] {
        guard !bundleID.isEmpty else { return [] }
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        let lowered = bundleID.lowercased()
        return objects.filter { object in
            var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
            var cf: Unmanaged<CFString>?
            var cfSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &cfSize, &cf) == noErr,
                  let id = cf?.takeRetainedValue() as String?
            else { return false }
            let candidate = id.lowercased()
            return candidate == lowered || candidate.hasPrefix(lowered + ".")
        }
    }

    static func defaultOutputDeviceUID() throws -> String {
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw AudioCapture.CaptureError.coreAudio("查找输出设备", status) }

        var uidAddress = Self.address(kAudioDevicePropertyDeviceUID)
        var cf: Unmanaged<CFString>?
        var cfSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &cfSize, &cf)
        guard status == noErr, let uid = cf?.takeRetainedValue() as String? else {
            throw AudioCapture.CaptureError.coreAudio("读取输出设备", status)
        }
        return uid
    }

    static func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }
}

/// Running apps that can be recorded, with common meeting apps and browsers first.
enum RecordableApps {
    struct App: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    static let preferred: [String] = [
        "com.tencent.meeting", "com.tencent.wemeetapp", "com.bytedance.macos.feishu", "com.electron.lark",
        "com.alibaba.DingTalkMac", "us.zoom.xos", "com.microsoft.teams2", "com.tencent.xinWeChat",
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "org.mozilla.firefox",
    ]

    static func running() -> [App] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> App? in
                guard let id = app.bundleIdentifier, id != own else { return nil }
                return App(bundleID: id, name: app.localizedName ?? id)
            }
        return apps.sorted { a, b in
            let ia = preferred.firstIndex(of: a.bundleID) ?? Int.max
            let ib = preferred.firstIndex(of: b.bundleID) ?? Int.max
            return ia != ib ? ia < ib : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }
}
#endif
