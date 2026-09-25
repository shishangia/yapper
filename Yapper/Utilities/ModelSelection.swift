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
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "transcriptionLanguage": defaultLanguage,
            "enableAutoEdit": true,
        ])
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
