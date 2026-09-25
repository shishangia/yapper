//
//  ModelSelection.swift
//  Yapper
//
//  Single source of truth for the user's selected transcription model.
//
//  The selection is stored once, in UserDefaults under `selectedModelVariant`, and
//  read via @AppStorage from every screen. Previously an unused `AppSettings.selectedModel`
//  enum shadowed this, and the @AppStorage default diverged between screens (the
//  dashboard defaulted to a concrete variant while others defaulted to empty), so
//  "no model selected" meant different things in different places.
//

import Foundation

enum ModelSelection {
    /// UserDefaults key backing the user's chosen model variant.
    static let defaultsKey = "selectedModelVariant"

    /// Value meaning "no model selected yet" — the single shared default.
    static let none = ""
    static let defaultLanguage = "hinglish"

    /// Hinglish is an output format backed by its specialist local model. The
    /// normal model selection remains available for every other language.
    static func resolvedVariant(_ selected: String, language: String) -> String {
        language == defaultLanguage ? AIModel.hinglishVariant : selected
    }

    /// Existing explicit language choices remain untouched by registered defaults.
    static func registerDefaults(
        _ defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier
    ) {
        if let domain { keepLegacyDefaults(defaults, domain: domain) }
        defaults.register(defaults: [
            "transcriptionLanguage": defaultLanguage,
            "enableAutoEdit": true,
        ])
    }

    /// Before 1.1.1, "auto" and Auto Edit off were unsaved @AppStorage fallbacks. Persist them
    /// once for installs that predate this check, so the new registered defaults only reach
    /// fresh installs. Reads the persistent domain because registered defaults are process-wide.
    private static func keepLegacyDefaults(_ defaults: UserDefaults, domain: String) {
        let migratedKey = "didKeepLegacyLanguageDefaults"
        let stored = defaults.persistentDomain(forName: domain) ?? [:]
        guard stored[migratedKey] == nil else { return }
        defaults.set(true, forKey: migratedKey)
        let existingInstall = stored["hasCompletedOnboarding"] as? Bool == true
            || stored[defaultsKey] != nil || stored["history_items"] != nil
        guard existingInstall else { return }
        if stored["transcriptionLanguage"] == nil { defaults.set("auto", forKey: "transcriptionLanguage") }
        if stored["enableAutoEdit"] == nil { defaults.set(false, forKey: "enableAutoEdit") }
    }

    static func selectedVariant(
        _ defaults: UserDefaults = .standard, language: String? = nil
    ) -> String {
        let output = language ?? defaults.string(forKey: "transcriptionLanguage") ?? defaultLanguage
        return resolvedVariant(defaults.string(forKey: defaultsKey) ?? none, language: output)
    }

    static func displayedVariant(
        _ selected: String, language: String
    ) -> String {
        resolvedVariant(selected, language: language)
    }
}
