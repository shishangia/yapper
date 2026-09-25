//
//  ModelStorage.swift
//  Yapper
//
//  All model downloads and tokenizer caches belong to this app's isolated store.
//  Older locations are read only by the explicit LegacyImportService operation.
//

import Foundation
import FluidAudio
import WhisperKit

enum ModelStorage {
    static let hinglishRepository = "shrimalmadhur/whisperkit-hinglish"
    static let hinglishRevision = "918fdea849d10e21ad2eff86d255e337afe2b1dc"
    static let hinglishFolder = "Oriserve_Whisper-Hindi2Hinglish-Apex"

    static func whisperVariant(for variant: String) -> ModelVariant? {
        if variant == AIModel.hinglishVariant || variant.contains("large-v3-v20240930") { return .largev3 }
        let name = variant.replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "_turbo", with: "")
        return ModelVariant.allCases.first { $0.description == name }
    }

    static func tokenizerDirectory(for variant: String) -> URL? {
        guard let model = whisperVariant(for: variant) else { return nil }
        return whisperKitBase.appendingPathComponent("models/openai/whisper-\(model.description)")
    }

    static func transcriptionModelReady(_ variant: String) -> Bool {
        guard let model = AIModel.availableModels.first(where: { $0.variant == variant }) else { return false }
        if model.engine == .parakeet {
            let version = ParakeetCatalog.version(for: variant)
            return AsrModels.modelsExist(at: parakeetCacheDirectory(for: version), version: version)
        }
        guard let tokenizer = tokenizerDirectory(for: variant) else { return false }
        let root = transcriptionModelDirectory(for: variant)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        } && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent($0).path)
        }
    }

    static func transcriptionModelDirectory(for variant: String) -> URL {
        if variant == AIModel.hinglishVariant {
            let hub = HubApiWrapper(downloadBase: whisperKitBase)
            return hub.localRepoLocation(.init(id: hinglishRepository))
                .appendingPathComponent(hinglishFolder, isDirectory: true)
        }
        return whisperKitModelsDir.appendingPathComponent(variant, isDirectory: true)
    }

    /// WhisperKit models and tokenizer configs both live below this base.
    static var whisperKitBase: URL { AppEnvironment.applicationSupportDirectory }

    /// FluidAudio resolves sibling repositories relative to this directory.
    static func parakeetCacheDirectory(for version: AsrModelVersion) -> URL {
        whisperKitBase
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(
                AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }

    static var whisperKitModelsDir: URL {
        whisperKitBase.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    static var fluidAudioModelsDir: URL {
        whisperKitBase.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    static var nemotronSpeakerDirectory: URL {
        fluidAudioModelsDir.appendingPathComponent("nemotron-3-diarization", isDirectory: true)
    }

    // The older engine call site uses this as its tokenizer base. It must never
    // fall back to Documents: the explicit import copies those tokenizers here.
    static var legacyBase: URL? { whisperKitBase }

    // Existing discovery/deletion call sites may not claim ownership of old data.
    static var legacyModelsDir: URL? { nil }

    @discardableResult
    static func ensureWhisperKitModelsDir() -> URL {
        let dir = whisperKitModelsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Kept for the existing downloader initializer; never move or copy user data
    /// during service construction. Import is a separate confirmed first-run action.
    static func migrateLegacyModelsIfNeeded() {}
}
