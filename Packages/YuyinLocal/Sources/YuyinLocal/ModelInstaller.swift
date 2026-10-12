import Foundation
import YuyinCore

#if canImport(FluidAudio)
import FluidAudio
#endif

public struct InstallProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case downloading
        case extracting
        case finishing
    }

    public var phase: Phase
    /// 0...1 within the phase.
    public var fraction: Double

    public init(phase: Phase, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }

    public var label: String {
        switch phase {
        case .downloading: return "下载中 \(Int(fraction * 100))%"
        case .extracting: return "解压中 \(Int(fraction * 100))%"
        case .finishing: return "安装中…"
        }
    }
}

public enum ModelInstallError: Error, LocalizedError {
    case http(Int)
    case invalidBundle(ModelKind)
    case unrecognizedFolder

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "模型下载失败（HTTP \(code)）"
        case .invalidBundle(let kind): return "「\(kind.title)」安装包内容不完整"
        case .unrecognizedFolder: return "无法识别所选文件夹中的模型（需要 sherpa-onnx 官方模型目录）"
        }
    }
}

/// Downloads to disk, extracts in a streaming fashion into a staging directory,
/// validates, then swaps the result into place. A failed or cancelled install never
/// leaves a half-written model behind.
public actor ModelInstaller {
    public let locator: ModelLocator

    public init(locator: ModelLocator = .standard) {
        self.locator = locator
    }

    public func install(_ kind: ModelKind, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        if kind == .senseVoiceANE {
            try await installFluidSenseVoice(progress: progress)
            return
        }
        if let files = kind.remoteFiles {
            try await installFiles(kind, files, progress: progress)
            return
        }
        guard let url = kind.remoteURL else { throw ModelInstallError.invalidBundle(kind) }

        let fm = FileManager.default
        try fm.createDirectory(at: locator.root, withIntermediateDirectories: true)
        let work = locator.root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let download = work.appendingPathComponent(url.lastPathComponent)
        progress(InstallProgress(phase: .downloading, fraction: 0))
        try await FileDownloader.download(url, to: download) { fraction in
            progress(InstallProgress(phase: .downloading, fraction: fraction))
        }
        try Task.checkCancellation()

        let staged = work.appendingPathComponent("bundle", isDirectory: true)
        if url.pathExtension == "onnx" {
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try fm.moveItem(at: download, to: staged.appendingPathComponent(url.lastPathComponent))
        } else {
            progress(InstallProgress(phase: .extracting, fraction: 0))
            try await Self.offloaded { isCancelled in
                try TarBz2Extractor.extract(archive: download, to: staged, isCancelled: isCancelled) { fraction in
                    progress(InstallProgress(phase: .extracting, fraction: fraction))
                }
            }
            try? fm.removeItem(at: download)
        }

        progress(InstallProgress(phase: .finishing, fraction: 1))
        guard let bundle = findBundle(kind, under: staged) else { throw ModelInstallError.invalidBundle(kind) }
        try replace(kind, with: bundle)
    }

    public func remove(_ kind: ModelKind) throws {
        let dir = locator.directory(for: kind)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Copies an already-extracted official model folder (e.g. from `Models/download.sh`
    /// or the Files app). Returns the detected kind.
    @discardableResult
    public func importFolder(_ folder: URL) async throws -> ModelKind {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        guard let kind = detectKind(of: folder) else { throw ModelInstallError.unrecognizedFolder }
        let fm = FileManager.default
        try fm.createDirectory(at: locator.root, withIntermediateDirectories: true)
        let work = locator.root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try await Self.offloaded { _ in try FileManager.default.copyItem(at: folder, to: work) }
        guard let bundle = findBundle(kind, under: work) else { throw ModelInstallError.invalidBundle(kind) }
        try replace(kind, with: bundle)
        return kind
    }

    // MARK: - Private

    /// Long blocking file work runs on a GCD queue (not the cooperative pool) and
    /// still honours task cancellation.
    private static func offloaded(_ work: @escaping @Sendable (_ isCancelled: @escaping () -> Bool) throws -> Void) async throws {
        let flag = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(with: Result { try work { flag.isSet } })
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    /// Plain files into one folder; each file tries its mirrors in order.
    private func installFiles(_ kind: ModelKind, _ files: [[URL]], progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: locator.root, withIntermediateDirectories: true)
        let work = locator.root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let staged = work.appendingPathComponent("bundle", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        for (index, mirrors) in files.enumerated() {
            var lastError: Error = ModelInstallError.invalidBundle(kind)
            var done = false
            for url in mirrors where !done {
                do {
                    try await FileDownloader.download(url, to: staged.appendingPathComponent(url.lastPathComponent)) { fraction in
                        progress(InstallProgress(phase: .downloading, fraction: (Double(index) + fraction) / Double(files.count)))
                    }
                    done = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            guard done else { throw lastError }
            try Task.checkCancellation()
        }
        progress(InstallProgress(phase: .finishing, fraction: 1))
        guard validates(kind, at: staged, shallow: true) else { throw ModelInstallError.invalidBundle(kind) }
        try replace(kind, with: staged)
    }

    private func installFluidSenseVoice(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        #if canImport(FluidAudio)
        progress(InstallProgress(phase: .downloading, fraction: 0))
        let directory = try await SenseVoiceModels.download { p in
            switch p.phase {
            case .compiling:
                progress(InstallProgress(phase: .finishing, fraction: p.fractionCompleted))
            default:
                progress(InstallProgress(phase: .downloading, fraction: p.fractionCompleted))
            }
        }
        // The first load compiles the model for the Neural Engine (can take a minute or more);
        // do it now so the first recording does not stall in "preparing".
        progress(InstallProgress(phase: .finishing, fraction: 1))
        _ = try SenseVoiceModels.load(from: directory)
        #else
        throw ASRError.unavailable("FluidAudio 未链接")
        #endif
    }

    private func replace(_ kind: ModelKind, with bundle: URL) throws {
        let fm = FileManager.default
        let dest = locator.directory(for: kind)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: bundle, to: dest)
    }

    /// The directory (root or one level down) that validates as a complete `kind`.
    private func findBundle(_ kind: ModelKind, under root: URL) -> URL? {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        // Prefer the innermost directory so the installed folder has the files at its top level.
        for candidate in dirs + [root] where validates(kind, at: candidate, shallow: true) {
            return candidate
        }
        return validates(kind, at: root, shallow: false) ? root : nil
    }

    private func validates(_ kind: ModelKind, at dir: URL, shallow: Bool) -> Bool {
        switch kind {
        case .qwen3ASRLarge:
            return (try? locator.ggufFiles(in: dir)) != nil
        case .streamingXASRFast, .streamingXASR, .streamingZipformer:
            guard let files = try? locator.streamingFiles(in: dir) else { return false }
            return !shallow || URL(fileURLWithPath: files.tokens).deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL
        case .senseVoice, .paraformer, .fireRed:
            guard let files = try? locator.offlineFiles(kind, in: dir) else { return false }
            return !shallow || URL(fileURLWithPath: files.tokens).deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL
        case .qwen3ASR, .funASRNano:
            guard (try? locator.offlineFiles(kind, in: dir)) != nil else { return false }
            let marker = kind == .qwen3ASR ? "conv_frontend.onnx" : "llm.int8.onnx"
            return !shallow || FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path)
        case .speakerEmbedding, .speakerSegmentation, .punctuation:
            guard let model = try? locator.singleModel(kind, in: dir) else { return false }
            return !shallow || URL(fileURLWithPath: model).deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL
        case .senseVoiceANE:
            return false
        }
    }

    private func detectKind(of folder: URL) -> ModelKind? {
        let name = folder.lastPathComponent.lowercased()
        if (try? locator.ggufFiles(in: folder)) != nil { return .qwen3ASRLarge }
        if (try? locator.offlineFiles(.qwen3ASR, in: folder)) != nil { return .qwen3ASR }
        if (try? locator.offlineFiles(.funASRNano, in: folder)) != nil { return .funASRNano }
        if name.contains("punct"), (try? locator.singleModel(.punctuation, in: folder)) != nil { return .punctuation }
        if (try? locator.offlineFiles(.fireRed, in: folder)) != nil { return .fireRed }
        if (try? locator.streamingFiles(in: folder)) != nil {
            if name.contains("x-asr") { return name.contains("160ms") ? .streamingXASRFast : .streamingXASR }
            return .streamingZipformer
        }
        if (try? locator.offlineFiles(.senseVoice, in: folder)) != nil {
            if name.contains("paraformer") { return .paraformer }
            if name.contains("sense") { return .senseVoice }
            // SenseVoice's vocabulary (~25k tokens) is far larger than Paraformer's (~8k).
            let tokens = ModelLocator.find(in: folder, exact: "tokens.txt").flatMap { try? String(contentsOfFile: $0) }
            let count = tokens?.split(separator: "\n").count ?? 0
            return count > 15_000 ? .senseVoice : .paraformer
        }
        if (try? locator.singleModel(.speakerSegmentation, in: folder)) != nil {
            if name.contains("segmentation") || name.contains("pyannote") { return .speakerSegmentation }
            if name.contains("speaker") || name.contains("eres2net") || name.contains("campplus") || name.contains("3dspeaker") {
                return .speakerEmbedding
            }
        }
        return nil
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// URLSession download straight to a file, with progress and cooperative cancellation.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReported = -1.0

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = FileDownloader(destination: destination, onProgress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.lock.withLock { delegate.continuation = cont }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let report: Bool = lock.withLock {
            guard fraction - lastReported >= 0.005 || fraction >= 1 else { return false }
            lastReported = fraction
            return true
        }
        if report { onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(ModelInstallError.http(http.statusCode)))
            return
        }
        do {
            // The temporary file is deleted when this method returns.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(ASRError.network(error.localizedDescription)))
            }
        }
    }
}
