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
    static func whisperVariant(for variant: String) -> ModelVariant? {
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
        let root = whisperKitModelsDir.appendingPathComponent(variant)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        } && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent($0).path)
        }
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
