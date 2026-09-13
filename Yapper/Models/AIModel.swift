import SwiftUI

struct AIModel: Identifiable, Equatable {
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

    var languageSupportLabel: String {
        isEnglishOnly ? "English-only" : "Multilingual"
    }

    var isEnglishOnly: Bool {
        englishOnlyOverride ?? variant.hasSuffix(".en")
    }

    func supports(language: String) -> Bool {
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
            name: "Whisper Large v3 Turbo",
            variant: "openai_whisper-large-v3_turbo",
            details: "Faster Large v3 variant for dictation and conversations.",
            size: "1.6 GB",
            speed: 7.0,
            accuracy: 9.5,
            expectedSizeBytes: 1_400_000_000,
            minimumRAMGB: 8
        ),
        AIModel(
            name: "Whisper Medium",
            variant: "openai_whisper-medium",
            details: "Medium-sized Whisper model.",
            size: "1.5 GB",
            speed: 5.5,
            accuracy: 8.9,
            expectedSizeBytes: 1_300_000_000,
            minimumRAMGB: 8
        ),
        AIModel(
            name: "Whisper Small",
            variant: "openai_whisper-small.en",
            details: "Small Whisper model trained for English.",
            size: "244 MB",
            speed: 8.0,
            accuracy: 8.5,
            expectedSizeBytes: 200_000_000,
            minimumRAMGB: 4
        ),
        AIModel(
            name: "Whisper Base",
            variant: "openai_whisper-base.en",
            details: "Compact Whisper model trained for English.",
            size: "74 MB",
            speed: 9.0,
            accuracy: 7.5,
            expectedSizeBytes: 70_000_000,
            minimumRAMGB: 2
        ),
        AIModel(
            name: "Whisper Tiny",
            variant: "openai_whisper-tiny",
            details: "The smallest Whisper download in this list.",
            size: "39 MB",
            speed: 9.5,
            accuracy: 6.0,
            expectedSizeBytes: 30_000_000,
            minimumRAMGB: 2
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
        AIModel(
            name: "Parakeet TDT v2",
            variant: ParakeetCatalog.v2Variant,
            details: "NVIDIA speech recognition trained for English.",
            size: "~2 GB",
            speed: 9.8,
            accuracy: 9.1,
            expectedSizeBytes: 500_000_000,
            minimumRAMGB: 4,
            engine: .parakeet,
            englishOnlyOverride: true
        ),
        AIModel(
            name: "Parakeet TDT-CTC 110M",
            variant: ParakeetCatalog.ctc110mVariant,
            details: "A smaller NVIDIA model with 110 million parameters.",
            size: "~450 MB",
            speed: 9.9,
            accuracy: 8.5,
            expectedSizeBytes: 200_000_000,
            minimumRAMGB: 2,
            engine: .parakeet,
            englishOnlyOverride: true
        ),
    ]

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

    /// All models for a given engine.
    static func models(for engine: TranscriptionEngineKind) -> [AIModel] {
        availableModels.filter { $0.engine == engine }
    }

    /// What the user primarily wants from transcription — biases the trade-off
    /// between real-time speed and raw accuracy.
    enum UseCase: String, CaseIterable, Identifiable {
        case dictation      // real-time typing; latency matters most
        case balanced
        case transcription  // files/meetings; accuracy matters most

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .balanced: return "Balanced"
            case .transcription: return "Transcription"
            }
        }

        /// (speed, accuracy) weighting, summing to 1.
        var weights: (speed: Double, accuracy: Double) {
            switch self {
            case .dictation: return (0.6, 0.4)
            case .balanced: return (0.4, 0.6)
            case .transcription: return (0.2, 0.8)
            }
        }
    }

    /// Recommends the best-fitting model for this Mac and use case, considering
    /// RAM, chip performance tier, and the Neural Engine — not just RAM.
    static func recommendedModel(
        for capability: DeviceCapability = .current,
        useCase: UseCase = .dictation
    ) -> AIModel {
        let fits = availableModels.filter { capability.ramGB >= $0.minimumRAMGB }
        let pool = fits.isEmpty ? availableModels : fits
        return pool.max {
            recommendationScore($0, capability: capability, useCase: useCase)
                < recommendationScore($1, capability: capability, useCase: useCase)
        } ?? availableModels.last!
    }

    /// 0.0–1.0-ish fitness score; higher is a better match for the machine + use case.
    static func recommendationScore(
        _ model: AIModel,
        capability: DeviceCapability,
        useCase: UseCase
    ) -> Double {
        let (wSpeed, wAccuracy) = useCase.weights
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

    /// A short, human explanation of why a model is recommended for this Mac.
    static func recommendationReason(
        for model: AIModel,
        capability: DeviceCapability = .current,
        useCase: UseCase = .dictation
    ) -> String {
        switch useCase {
        case .dictation:
            return "A speed-focused suggestion for your \(capability.chipName). Actual speed depends on the recording."
        case .balanced:
            return "A balance of estimated speed and accuracy for your \(capability.chipName)."
        case .transcription:
            return "An accuracy-focused suggestion within your Mac's \(capability.ramGB) GB memory budget."
        }
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
