//
//  LicenseManager.swift
//  Yapper
//
//  Retained for existing settings bindings. This personal fork does not use
//  upstream licensing, and initialization never reads Keychain or contacts a server.
//

import Foundation
import Combine

enum LicenseError: LocalizedError {
    case invalidKey
    case networkError
    case validationFailed(String)
    case keychainError
    case expiredKey
    case activationLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "The license key format is invalid."
        case .networkError: return "License services are unavailable in Yapper."
        case .validationFailed(let message): return message
        case .keychainError: return "Failed to update the local license key."
        case .expiredKey: return "This license key has expired."
        case .activationLimitReached: return "This license key has reached its activation limit."
        }
    }
}

@MainActor
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var isPro = false
    @Published private(set) var licenseKey: String?
    @Published private(set) var expirationDate: Date?
    @Published private(set) var isValidating = false

    init() {}

    func activateLicense(key: String) async throws {
        throw LicenseError.validationFailed(
            "Yapper does not use license keys. Its features are available without activation.")
    }

    func deactivateLicense() async throws {
        // Only the Yapper namespace is addressable; never access legacy keys.
        try KeychainHelper.shared.deleteLicenseKey()
        licenseKey = nil
        expirationDate = nil
        isPro = false
    }
}
