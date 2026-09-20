import AppKit
import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()
    nonisolated static let trustedUpdateBundleIdentifier = "com.shishangia.yapper"
    nonisolated static let trustedUpdateTeamIdentifier = "R35KZD8A54"
    @Published var availableUpdate: AppVersion?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var checkStatus = ""
    @Published private(set) var isInstalling = false
    private(set) var isRestarting = false
    @Published private(set) var installProgress: Double = 0
    @Published private(set) var installPhase = ""
    @Published private(set) var installStatus = ""
    @Published private(set) var installError: String?
    var isWorkActive: () -> Bool = { true }
    let showUpdateWindowPublisher = PassthroughSubject<AppVersion, Never>()

    private override init() {
        super.init()
        lastCheckDate = UserDefaults.standard.object(forKey: "lastUpdateCheckDate") as? Date
    }

    func checkForUpdates(silent: Bool = false) async {
        guard AppEnvironment.updatesEnabled, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        checkStatus = "Checking GitHub…"
        defer { isCheckingForUpdates = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/shishangia/yapper/releases/latest")!)
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Yapper/\(AppVersion.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { throw UpdateError.downloadFailed("GitHub could not provide release information. Try again later.") }
            let release = try AppVersion(from: JSONDecoder().decode(GitHubRelease.self, from: data))
            lastCheckDate = Date()
            UserDefaults.standard.set(lastCheckDate, forKey: "lastUpdateCheckDate")
            let newer = AppVersion.isNewerVersion(release.version, than: AppVersion.currentVersion)
                || release.version == AppVersion.currentVersion && AppVersion.isNewerVersion(release.buildNumber, than: AppVersion.currentBuildNumber)
            availableUpdate = newer ? release : nil
            checkStatus = newer ? "Yapper \(release.version) is available." : "You're up to date."
            if newer, (!silent || UserDefaults.standard.string(forKey: "skippedVersion") != release.version), !isWorkActive() {
                showUpdateWindowPublisher.send(release)
            }
        } catch { checkStatus = error.localizedDescription }
    }

    func shouldCheckForUpdates() -> Bool {
        AppEnvironment.updatesEnabled && Date().timeIntervalSince(lastCheckDate ?? .distantPast) >= 86400
    }
    func shouldShowReminder() -> Bool {
        availableUpdate != nil && Date().timeIntervalSince(UserDefaults.standard.object(forKey: "lastUpdateReminderDate") as? Date ?? .distantPast) >= 86400
    }
    func skipVersion(_ version: String) { UserDefaults.standard.set(version, forKey: "skippedVersion"); availableUpdate = nil }
    func markReminderShown() { UserDefaults.standard.set(Date(), forKey: "lastUpdateReminderDate") }
    func clearSkippedVersion() { UserDefaults.standard.removeObject(forKey: "skippedVersion") }
    var isAutoUpdateEnabled: Bool {
        get { AppEnvironment.updatesEnabled && (UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    func installUpdate(url: String) {
        guard AppEnvironment.updatesEnabled, !isInstalling, !isWorkActive(), let update = availableUpdate,
              update.downloadURL == url, let downloadURL = URL(string: url), update.sha256 != nil, update.downloadSize != nil else {
            installError = "Finish recording, transcription, or model downloads before installing an update."
            return
        }
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Yapper.app" else {
            installError = "Move Yapper to Applications and open that copy before updating."
            return
        }
        isInstalling = true
        installError = nil
        installPhase = "Downloading"
        installStatus = "Downloading the verified Mac installer…"
        installProgress = 0
        Task {
            var download: URL?
            var mount: URL?
            var staged: URL?
            var helper: URL?
            var handedOff = false
            defer {
                if let mount { _ = try? Self.command("/usr/bin/hdiutil", ["detach", mount.path]) }
                if let download { try? FileManager.default.removeItem(at: download) }
                if !handedOff {
                    if let staged { try? FileManager.default.removeItem(at: staged) }
                    if let helper { try? FileManager.default.removeItem(at: helper) }
                    isInstalling = false
                }
            }
            do {
                var request = URLRequest(url: downloadURL)
                request.timeoutInterval = 300
                let (temporary, response) = try await URLSession.shared.download(for: request)
                download = temporary
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      response.url?.scheme == "https" else { throw UpdateError.downloadFailed("The download did not succeed.") }
                installPhase = "Verifying"
                installStatus = "Checking checksum, app identity, and Apple signature…"
                installProgress = 0.65
                try await Task.detached {
                    try Self.verifyDownload(at: temporary, expectedSize: update.downloadSize!, sha256: update.sha256!)
                    _ = try Self.command("/usr/bin/hdiutil", ["verify", temporary.path])
                }.value
                let mountURL = FileManager.default.temporaryDirectory.appendingPathComponent("Yapper-update-\(UUID().uuidString)")
                _ = try await Task.detached { try Self.command("/usr/bin/hdiutil", ["attach", temporary.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountURL.path]) }.value
                mount = mountURL
                let candidate = mountURL.appendingPathComponent("Yapper.app")
                try await Task.detached { try Self.verifyCandidateApp(at: candidate, version: update.version, build: update.buildNumber) }.value
                guard !isWorkActive() else { throw UpdateError.copyFailed("Another operation started. Try again when it finishes.") }
                let destination = Bundle.main.bundleURL
                let stage = destination.deletingLastPathComponent().appendingPathComponent(".Yapper-update-\(UUID().uuidString).app")
                staged = stage
                try await Task.detached {
                    _ = try Self.command("/usr/bin/ditto", [candidate.path, stage.path])
                    try Self.verifyCandidateApp(at: stage, version: update.version, build: update.buildNumber)
                    _ = try Self.command("/usr/bin/hdiutil", ["detach", mountURL.path])
                }.value
                mount = nil
                guard !isWorkActive() else { throw UpdateError.copyFailed("Another operation started. Try again when it finishes.") }
                let script = FileManager.default.temporaryDirectory.appendingPathComponent("Yapper-install-\(UUID().uuidString).sh")
                helper = script
                try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
                let backup = destination.deletingLastPathComponent().appendingPathComponent(".Yapper-rollback-\(UUID().uuidString).app")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), stage.path, destination.path, backup.path, "/usr/bin/open"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                handedOff = true
                isRestarting = true
                installProgress = 1
                installPhase = "Restarting"
                installStatus = "The app will restart. Your library stays in place."
                NSApplication.shared.terminate(nil)
            } catch {
                installError = error.localizedDescription
                installPhase = ""
                installStatus = "Your installed app has not been replaced."
            }
        }
    }

    // Arguments, rather than interpolated paths, keep the handoff safe for arbitrary filesystem names.
    static let installScript = """
    set -eu
    pid="$1"; stage="$2"; dest="$3"; backup="$4"; opener="$5"
    trap 'rm -f "$0"' EXIT
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n+1))
      if [ "$n" -ge 600 ]; then rm -rf "$stage"; exit 1; fi
      sleep 0.2
    done
    /usr/bin/codesign --verify --deep --strict "$stage" || exit 1
    mv "$dest" "$backup" || exit 1
    if ! mv "$stage" "$dest"; then mv "$backup" "$dest"; "$opener" "$dest"; exit 1; fi
    if ! "$opener" "$dest"; then mv "$dest" "$stage"; mv "$backup" "$dest"; "$opener" "$dest"; exit 1; fi
    """

    nonisolated static func verifyDownload(at url: URL, expectedSize: Int64, sha256: String) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(expectedSize) else { throw UpdateError.verificationFailed }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw UpdateError.verificationFailed }
    }

    nonisolated static func verifyCandidateApp(at url: URL, version: String, build: String) throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == trustedUpdateBundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version,
              bundle.infoDictionary?["CFBundleVersion"] as? String == build else { throw UpdateError.invalidCandidateApp("Downloaded app identity or version does not match the release.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError.signatureVerificationFailed }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(trustedUpdateRequirementString(bundleIdentifier: trustedUpdateBundleIdentifier, teamIdentifier: trustedUpdateTeamIdentifier) as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { throw UpdateError.signatureVerificationFailed }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any] else { throw UpdateError.signatureVerificationFailed }
        try validateSigningInfo(signing, expectedBundleIdentifier: trustedUpdateBundleIdentifier, expectedTeamIdentifier: trustedUpdateTeamIdentifier)
        _ = try command("/usr/sbin/spctl", ["--assess", "--type", "execute", url.path])
    }

    @discardableResult
    nonisolated static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.copyFailed("\(URL(fileURLWithPath: executable).lastPathComponent) failed. Your existing app is retained.") }
        return data
    }

    nonisolated static func trustedUpdateRequirementString(bundleIdentifier: String, teamIdentifier: String) -> String {
        "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }
    nonisolated static func validateSigningInfo(_ signingInfo: [String: Any], expectedBundleIdentifier: String, expectedTeamIdentifier: String) throws {
        guard signingInfo[kSecCodeInfoIdentifier as String] as? String == expectedBundleIdentifier else { throw UpdateError.invalidCandidateApp("Downloaded update has an unexpected bundle identifier.") }
        guard signingInfo[kSecCodeInfoTeamIdentifier as String] as? String == expectedTeamIdentifier else { throw UpdateError.untrustedDeveloper }
    }
}

enum UpdateError: LocalizedError, Equatable {
    case downloadFailed(String), mountFailed, appNotFoundInDMG, copyFailed(String), verificationFailed
    case invalidCandidateApp(String), signatureVerificationFailed, untrustedDeveloper, gatekeeperAssessmentFailed
    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason): return "Update download failed: \(reason)"
        case .copyFailed(let reason), .invalidCandidateApp(let reason): return reason
        case .mountFailed: return "Could not open the update disk image."
        case .appNotFoundInDMG: return "The update contains no Yapper app."
        case .verificationFailed: return "The release or its checksum could not be verified."
        case .signatureVerificationFailed, .untrustedDeveloper: return "The update is not signed by Yapper's expected developer."
        case .gatekeeperAssessmentFailed: return "macOS rejected this update."
        }
    }
}
