import XCTest
import YuyinCore
@testable import YuyinLocal

final class ArchiveAndCatalogTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yuyin-local-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func sh(_ args: [String], in dir: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeTree() throws -> (URL, [String: Data]) {
        let src = tmp.appendingPathComponent("src/sherpa-onnx-test-model", isDirectory: true)
        let longDir = String(repeating: "d", count: 80)
        let longName = String(repeating: "n", count: 90) + ".onnx"
        var files: [String: Data] = [
            "tokens.txt": Data("<blk> 0\n你 1\n".utf8),
            "model.int8.onnx": Data((0..<300_000).map { UInt8($0 % 251) }),
            "empty.txt": Data(),
            "\(longDir)/\(longName)": Data("long path".utf8),
        ]
        files["big.bin"] = Data(count: 3_000_000)
        for (path, data) in files {
            let url = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return (src, files)
    }

    func testExtractsTarBz2IncludingLongPaths() throws {
        let (src, files) = try makeTree()
        let archive = tmp.appendingPathComponent("m.tar.bz2")
        XCTAssertEqual(try sh(["tar", "-cjf", archive.path, "-C", src.deletingLastPathComponent().path, src.lastPathComponent], in: tmp), 0)

        let out = tmp.appendingPathComponent("out", isDirectory: true)
        var last = 0.0
        try TarBz2Extractor.extract(archive: archive, to: out, progress: { last = $0 })
        XCTAssertEqual(last, 1, accuracy: 0.001)
        for (path, data) in files {
            let url = out.appendingPathComponent(src.lastPathComponent).appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: url), data, path)
        }
    }

    func testExtractsConcatenatedBzip2Streams() throws {
        let (src, files) = try makeTree()
        let tar = tmp.appendingPathComponent("m.tar")
        XCTAssertEqual(try sh(["tar", "-cf", tar.path, "-C", src.deletingLastPathComponent().path, src.lastPathComponent], in: tmp), 0)
        let bytes = try Data(contentsOf: tar)
        let half = bytes.count / 2 + 7
        try bytes[..<half].write(to: tmp.appendingPathComponent("a"))
        try bytes[half...].write(to: tmp.appendingPathComponent("b"))
        XCTAssertEqual(try sh(["bzip2", "-k", "a", "b"], in: tmp), 0)
        let joined = try Data(contentsOf: tmp.appendingPathComponent("a.bz2")) + Data(contentsOf: tmp.appendingPathComponent("b.bz2"))
        let archive = tmp.appendingPathComponent("pbzip.tar.bz2")
        try joined.write(to: archive)

        let out = tmp.appendingPathComponent("out", isDirectory: true)
        try TarBz2Extractor.extract(archive: archive, to: out)
        let tokens = out.appendingPathComponent(src.lastPathComponent).appendingPathComponent("tokens.txt")
        XCTAssertEqual(try Data(contentsOf: tokens), files["tokens.txt"])
    }

    func testTruncatedArchiveFails() throws {
        let (src, _) = try makeTree()
        let archive = tmp.appendingPathComponent("m.tar.bz2")
        XCTAssertEqual(try sh(["tar", "-cjf", archive.path, "-C", src.deletingLastPathComponent().path, src.lastPathComponent], in: tmp), 0)
        let data = try Data(contentsOf: archive)
        try data.prefix(data.count / 2).write(to: archive)
        XCTAssertThrowsError(try TarBz2Extractor.extract(archive: archive, to: tmp.appendingPathComponent("out")))
    }

    func testUnsafePathsAreRejected() throws {
        XCTAssertThrowsError(try TarStreamParser.safeURL(for: "/etc/passwd", in: tmp))
        XCTAssertThrowsError(try TarStreamParser.safeURL(for: "model/../../evil", in: tmp))
        XCTAssertNil(try TarStreamParser.safeURL(for: "model/._tokens.txt", in: tmp))
        XCTAssertNil(try TarStreamParser.safeURL(for: "__MACOSX/model/x", in: tmp))
        XCTAssertEqual(try TarStreamParser.safeURL(for: "./model//a.onnx", in: tmp)?.lastPathComponent, "a.onnx")
    }

    func testLocatorPrefersInt8EncoderAndFullDecoder() throws {
        let locator = ModelLocator(root: tmp, fluidRoot: tmp.appendingPathComponent("fluid"))
        let dir = locator.directory(for: .streamingZipformer)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("test_wavs"), withIntermediateDirectories: true)
        for name in ["tokens.txt", "encoder-epoch-99-avg-1.onnx", "encoder-epoch-99-avg-1.int8.onnx",
                     "decoder-epoch-99-avg-1.onnx", "decoder-epoch-99-avg-1.int8.onnx",
                     "joiner-epoch-99-avg-1.int8.onnx"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertFalse(locator.isInstalled(.senseVoice), "empty dirs from v0.1 are not 'installed'")
        XCTAssertTrue(locator.isInstalled(.streamingZipformer))
        let files = try locator.streamingFiles()
        XCTAssertTrue(files.encoder.hasSuffix("encoder-epoch-99-avg-1.int8.onnx"))
        XCTAssertTrue(files.decoder.hasSuffix("decoder-epoch-99-avg-1.onnx"))
        XCTAssertTrue(files.joiner.hasSuffix("joiner-epoch-99-avg-1.int8.onnx"))
    }

    func testResolutionFallsBackAndFailsLoudly() throws {
        let locator = ModelLocator(root: tmp, fluidRoot: tmp.appendingPathComponent("fluid"))
        let noSpeech = LocalEngines(locator: locator, onDeviceSpeech: { false })
        XCTAssertThrowsError(try noSpeech.resolveStreaming(.auto))
        XCTAssertThrowsError(try noSpeech.resolveCorrector(.senseVoice))
        XCTAssertEqual(try noSpeech.resolveCorrector(.auto), .none)

        let withSpeech = LocalEngines(locator: locator, onDeviceSpeech: { true })
        XCTAssertEqual(try withSpeech.resolveStreaming(.auto), .appleSpeech)

        let sv = locator.directory(for: .senseVoice)
        try FileManager.default.createDirectory(at: sv, withIntermediateDirectories: true)
        try Data().write(to: sv.appendingPathComponent("tokens.txt"))
        try Data().write(to: sv.appendingPathComponent("model.int8.onnx"))
        XCTAssertEqual(try withSpeech.resolveCorrector(.auto), .sherpa(.senseVoice))
    }

    func testImportDetectsAndInstallsFolder() async throws {
        let locator = ModelLocator(root: tmp.appendingPathComponent("models"), fluidRoot: tmp.appendingPathComponent("fluid"))
        let folder = tmp.appendingPathComponent("downloads/sherpa-onnx-paraformer-zh-2023-09-14", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a 1\n".utf8).write(to: folder.appendingPathComponent("tokens.txt"))
        try Data().write(to: folder.appendingPathComponent("model.int8.onnx"))
        let kind = try await ModelInstaller(locator: locator).importFolder(folder)
        XCTAssertEqual(kind, .paraformer)
        XCTAssertTrue(locator.isInstalled(.paraformer))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "import copies, never moves")
    }
}
