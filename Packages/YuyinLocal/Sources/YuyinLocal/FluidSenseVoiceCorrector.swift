import Foundation
import YuyinCore

#if canImport(FluidAudio)
import FluidAudio
#endif

/// SenseVoice-Small on the Apple Neural Engine via FluidAudio.
/// Loads only from disk: models are downloaded explicitly from Settings, never during a session.
public actor FluidSenseVoiceCorrector: CorrectorASREngine {
    public nonisolated let providerID = "ane-sensevoice"
    private let directory: URL

    #if canImport(FluidAudio)
    private var manager: SenseVoiceManager?
    #endif

    /// FunASR SenseVoice embedding indexes: language `zh` = 3, text norm `withitn` = 14
    /// (punctuation + inverse text normalization; FluidAudio defaults to 15 = none).
    private static let languageZh: Int32 = 3
    private static let textNormWithITN: Int32 = 14

    public init(directory: URL) {
        self.directory = directory
    }

    public static func modelsExist(at directory: URL) -> Bool {
        #if canImport(FluidAudio)
        return SenseVoiceModels.modelsExist(at: directory)
        #else
        return false
        #endif
    }

    public func prepare() async throws {
        #if canImport(FluidAudio)
        guard Self.modelsExist(at: directory) else {
            throw ASRError.modelMissing(ModelKind.senseVoiceANE.title)
        }
        let models = try SenseVoiceModels.load(from: directory)
        manager = SenseVoiceManager(models: models, language: Self.languageZh, textNorm: Self.textNormWithITN)
        #else
        throw ASRError.unavailable("FluidAudio 未链接")
        #endif
    }

    public func correct(_ samples: [Float], hint: String) async throws -> String {
        #if canImport(FluidAudio)
        guard let manager else { throw ASRError.notPrepared }
        guard !samples.isEmpty else { return hint }
        let text = try await manager.transcribe(audio: samples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? hint : text
        #else
        return hint
        #endif
    }

    public func shutdown() async {
        #if canImport(FluidAudio)
        manager = nil
        #endif
    }
}
