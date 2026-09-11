//
//  ModelStorage.swift
//  Yapper
//
//  All model downloads and tokenizer caches belong to this app's isolated store.
//  Older locations are read only by the explicit LegacyImportService operation.
//

import Foundation
import FluidAudio

enum ModelStorage {
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
