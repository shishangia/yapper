import FluidAudio
import XCTest
@testable import Yapper

final class ModelCatalogTests: XCTestCase {
    func testRemovedSelectionsMoveToClosestKeptModel() throws {
        let suite = "Yapper-Catalog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = [
            "openai_whisper-large-v3_turbo": "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-tiny": "openai_whisper-large-v3-v20240930_turbo",
            "parakeet-tdt-0.6b-v2": ParakeetCatalog.v3Variant,
            "parakeet-tdt-ctc-110m": ParakeetCatalog.v3Variant,
            "openai_whisper-large-v3": "openai_whisper-large-v3",
        ]
        for (old, new) in expected {
            defaults.set(old, forKey: ModelSelection.defaultsKey)
            AIModel.migrateRemovedSelection(defaults)
            XCTAssertEqual(defaults.string(forKey: ModelSelection.defaultsKey), new)
        }
        XCTAssertTrue(AIModel.removedVariantReplacements.values.allSatisfy { variant in
            AIModel.availableModels.contains { $0.variant == variant }
        })
    }

    func testUnusedFoldersSkipCatalogAndSpeakerModels() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = [
            "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3",
            "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo",
            "models/openai/whisper-large-v3",
            "models/openai/whisper-tiny",
            "FluidAudio/Models/nemotron-3-diarization",
            "FluidAudio/Models/" + AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent,
            "FluidAudio/Models/" + AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent,
        ]
        for path in paths {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let unused = Set(AIModel.unusedModelFolders(base: base).map { $0.lastPathComponent })
        XCTAssertEqual(unused, ["openai_whisper-large-v3_turbo", "whisper-tiny",
            AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent])
    }
}
