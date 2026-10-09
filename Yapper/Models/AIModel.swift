import FluidAudio
import SwiftUI

struct AIModel: Identifiable, Equatable {
    static let hinglishVariant = "oriserve_whisper-hindi2hinglish-apex"

    var id: String { variant }
    let name: String
    let variant: String
    let details: String
    let size: String
    // Legacy recommendation weights, not measured performance or UI ratings.
    let speed: Double
    let accuracy: Double
    let expectedSizeBytes: Int64  // Minimum expected size in bytes for validation
    let minimumRAMGB: Int  // Minimum device RAM in GB for reliable loading
    /// Which backend runs this model. Defaults to `.whisper` so existing
    /// catalog entries and call sites are unaffected. (Declared `var` so it is
    /// part of the synthesized memberwise initializer with a default.)
    var engine: TranscriptionEngineKind = .whisper
    /// Explicit English-only flag for engines that don't encode it in the
    /// variant name (e.g. Parakeet). When nil, falls back to the Whisper
    /// `.en` suffix convention.
    var englishOnlyOverride: Bool? = nil
    /// Specialist models are shown in the catalog but are not suggested as a
    /// general-purpose default for languages they were not trained on.
    var isSpecialized: Bool = false
    var downloadRepository: String? = nil
    var downloadRevision: String? = nil
    var downloadFolder: String? = nil

    var languageSupportLabel: String {
        if isHinglish { return "Hindi + English · Latin script" }
        return isEnglishOnly ? "English-only" : "Multilingual"
    }

    var isHinglish: Bool { variant == Self.hinglishVariant }

    var isEnglishOnly: Bool {
        englishOnlyOverride ?? variant.hasSuffix(".en")
    }

    func supports(language: String) -> Bool {
        if isHinglish { return ["auto", "en", "hi", "hinglish", "mr", "mixed"].contains(language) }
        if language == "auto" { return true }
        if isEnglishOnly { return language == "en" }
        if engine == .parakeet {
            return ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"].contains(language)
        }
        return language == "mixed" || GeneralSettingsTab.whisperLanguages.contains { $0.code == language }
    }

    // Preserve the existing recommendation ordering. These weights are heuristic
    // inputs only; model choice still requires an explicit user action.
    static let availableModels: [AIModel] = [
        AIModel(
            name: "Whisper Large v3 Turbo",
            variant: "openai_whisper-large-v3-v20240930_turbo",
            details: "OpenAI's four-layer Turbo model for faster multilingual dictation and conversations.",
            size: "1.6 GB",
            speed: 7.0,
            accuracy: 9.5,
            expectedSizeBytes: 1_500_000_000,
            minimumRAMGB: 8
        ),
        AIModel(
            name: "Whisper Large v3",
            variant: "openai_whisper-large-v3",
            details: "Full multilingual Whisper model for detailed transcription.",
            size: "~3 GB",
            speed: 4.0,
            accuracy: 9.5,
            expectedSizeBytes: 2_800_000_000,
            minimumRAMGB: 16
        ),
        AIModel(
            name: "Whisper Hinglish Turbo",
            variant: hinglishVariant,
            details: "Hindi and English speech in natural Latin script. Tested locally on mixed Hinglish audio.",
            size: "1.6 GB",
            speed: 7.0,
            accuracy: 8.8,
            expectedSizeBytes: 1_500_000_000,
            minimumRAMGB: 8,
            isSpecialized: true,
            downloadRepository: ModelStorage.hinglishRepository,
            downloadRevision: ModelStorage.hinglishRevision,
            downloadFolder: ModelStorage.hinglishFolder
        ),
        // NVIDIA Parakeet (run on-device via FluidAudio / CoreML).
        // Download size is approximate (FluidAudio fetches the int8 weight set).
        AIModel(
            name: "Parakeet TDT v3",
            variant: ParakeetCatalog.v3Variant,
            details: "NVIDIA speech recognition for 25 languages.",
            size: "~2 GB",
            speed: 9.7,
            accuracy: 9.2,
            expectedSizeBytes: 500_000_000,
            minimumRAMGB: 4,
            engine: .parakeet
        ),
    ]

    /// Selections from models removed in 1.3.0 move to the closest kept model.
    /// Their files stay on disk until the user removes them in Settings > Models.
    static let removedVariantReplacements: [String: String] = [
        "openai_whisper-large-v3_turbo": "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-medium": "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-small.en": "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-base.en": "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-tiny": "openai_whisper-large-v3-v20240930_turbo",
        "parakeet-tdt-0.6b-v2": ParakeetCatalog.v3Variant,
        "parakeet-tdt-ctc-110m": ParakeetCatalog.v3Variant,
    ]

    static func migrateRemovedSelection(_ defaults: UserDefaults = .standard) {
        guard let selected = defaults.string(forKey: ModelSelection.defaultsKey),
              let replacement = removedVariantReplacements[selected] else { return }
        defaults.set(replacement, forKey: ModelSelection.defaultsKey)
    }

    /// Downloaded model folders that no catalog model uses: removed Whisper and
    /// Parakeet variants and their tokenizers. Speaker models are never included.
    static func unusedModelFolders(base: URL = ModelStorage.whisperKitBase) -> [URL] {
        let files = FileManager.default
        func children(_ dir: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        let whisperModels = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let kept = Set(availableModels.map(\.variant))
        let tokenizers = base.appendingPathComponent("models/openai", isDirectory: true)
        let keptTokenizers = Set(availableModels.compactMap {
            ModelStorage.tokenizerDirectory(for: $0.variant)?.lastPathComponent
        })
        let parakeet = base.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let removedParakeet = Set([AsrModelVersion.v2, .tdtCtc110m].map {
            AsrModels.defaultCacheDirectory(for: $0).lastPathComponent
        })
        return children(whisperModels).filter { !kept.contains($0.lastPathComponent) }
            + children(tokenizers).filter { !keptTokenizers.contains($0.lastPathComponent) }
            + children(parakeet).filter { removedParakeet.contains($0.lastPathComponent) }
    }

    static func allocatedSize(of folders: [URL]) -> Int64 {
        var total: Int64 = 0
        for folder in folders {
            let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            while let item = items?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    /// Returns the expected minimum size for a given model variant
    static func expectedSize(for variant: String) -> Int64 {
        return availableModels.first(where: { $0.variant == variant })?.expectedSizeBytes
            ?? 50_000_000
    }

    /// Returns which backend owns a given model variant.
    /// Defaults to `.whisper` for unknown variants so existing behavior is preserved.
    static func engineKind(for variant: String) -> TranscriptionEngineKind {
        return availableModels.first(where: { $0.variant == variant })?.engine ?? .whisper
    }

    /// Recommends the best-fitting model for this Mac, weighing speed and accuracy
    /// evenly-ish (40/60) and considering RAM, chip tier, and the Neural Engine.
    static func recommendedModel(for capability: DeviceCapability = .current) -> AIModel {
        let fits = availableModels.filter {
            !$0.isSpecialized && capability.ramGB >= $0.minimumRAMGB
        }
        let pool = fits.isEmpty ? availableModels : fits
        return pool.max {
            recommendationScore($0, capability: capability) < recommendationScore($1, capability: capability)
        } ?? availableModels.last!
    }

    /// 0.0–1.0-ish fitness score; higher is a better match for the machine.
    static func recommendationScore(_ model: AIModel, capability: DeviceCapability) -> Double {
        let (wSpeed, wAccuracy) = (0.4, 0.6)
        let speedN = model.speed / 10.0
        let accuracyN = model.accuracy / 10.0

        // A slow model feels slower on a weaker Mac, so scale perceived speed by
        // the device tier (weak machines drag large/slow models down).
        let effectiveSpeed = speedN * (0.5 + 0.5 * capability.performanceTier)

        var score = wSpeed * effectiveSpeed + wAccuracy * accuracyN

        // Lightly reward comfortable RAM headroom so we don't pick a model that
        // only just fits.
        let headroom = Double(capability.ramGB - model.minimumRAMGB)
        score += min(0.1, max(0, headroom) * 0.01)

        // Intel Macs have no Neural Engine and struggle with the largest models.
        if !capability.hasNeuralEngine && model.expectedSizeBytes > 1_000_000_000 {
            score -= 0.15
        }

        return score
    }

    /// Backward-compatible RAM-only recommendation used by older call sites.
    static func recommendedModel(forDeviceRAMGB ram: Int) -> AIModel {
        return availableModels.first(where: { ram >= $0.minimumRAMGB })
            ?? availableModels.last!  // Fallback to smallest
    }

    /// Returns a warning string if this model may not work well on the device, nil otherwise
    func ramWarning(deviceRAMGB: Int) -> String? {
        guard deviceRAMGB < minimumRAMGB else { return nil }
        return "Requires \(minimumRAMGB)GB+ RAM — your Mac has \(deviceRAMGB)GB"
    }
}
