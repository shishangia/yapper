import Foundation

/// Build and process boundaries shared by storage and app startup.
enum AppEnvironment {
    static var isDevelopment: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    // SwiftUI can load XCTest classes later; storage identity must never change mid-process.
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    static var usesIsolatedStorage: Bool { isDevelopment || isRunningTests }
    static var globalHotkeysEnabled: Bool { !isDevelopment && !isRunningTests }
    static var updatesEnabled: Bool {
        #if DEBUG
            return false
        #else
            return !isRunningTests
        #endif
    }

    static var displayName: String { isDevelopment ? "Yapper-Dev" : "Yapper" }
    static var urlScheme: String { isDevelopment ? "yapper-dev" : "yapper" }

    static var defaultsDomain: String {
        if isRunningTests { return "com.shishangia.yapper.tests.\(ProcessInfo.processInfo.processIdentifier)" }
        return isDevelopment ? "com.shishangia.yapper.dev" : "com.shishangia.yapper"
    }

    /// Resolving a path does not create it or read production data.
    static var applicationSupportDirectory: URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "Yapper-Tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent(
            isDevelopment ? "Yapper-Dev" : "Yapper", isDirectory: true)
    }
}
