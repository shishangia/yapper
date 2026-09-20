import Security
import XCTest
@testable import Yapper

final class UpdateServiceSecurityTests: XCTestCase {

    func testTrustedUpdateRequirementStringPinsBundleAndTeam() {
        let requirement = UpdateService.trustedUpdateRequirementString(
            bundleIdentifier: "com.example.app",
            teamIdentifier: "TEAM123456"
        )

        XCTAssertEqual(
            requirement,
            #"identifier "com.example.app" and anchor apple generic and certificate leaf[subject.OU] = "TEAM123456" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
        )
    }

    @MainActor
    func testReleaseSelectionRejectsWrongPlatformAndMissingIntegrity() throws {
        let tag = "v1.0.3"
        let name = "Yapper-1.0.3-7-arm64.dmg"
        let asset = GitHubAsset(name: name, browserDownloadUrl: "https://github.com/shishangia/yapper/releases/download/\(tag)/\(name)", digest: "sha256:" + String(repeating: "a", count: 64), size: 100)
        let release = GitHubRelease(tagName: tag, body: "Notes", htmlUrl: "", publishedAt: "2026-09-19T00:00:00Z", assets: [asset], draft: false, prerelease: false)
        let update = try AppVersion(from: release)
        XCTAssertEqual(update.version, "1.0.3")
        XCTAssertEqual(update.buildNumber, "7")
        XCTAssertThrowsError(try AppVersion(from: GitHubRelease(tagName: "windows-v0.1.0-preview.2", body: "", htmlUrl: "", publishedAt: "", assets: [asset], draft: false, prerelease: true)))
        let missingDigest = GitHubAsset(name: name, browserDownloadUrl: asset.browserDownloadUrl, digest: nil, size: 100)
        XCTAssertThrowsError(try AppVersion(from: GitHubRelease(tagName: tag, body: "", htmlUrl: "", publishedAt: "", assets: [missingDigest], draft: false, prerelease: false)))
        XCTAssertFalse(AppVersion.isTrustedDownload("https://github.com.evil.test/shishangia/yapper/releases/download/\(tag)/\(name)", tag: tag, name: name))
        XCTAssertFalse(AppVersion.isTrustedDownload(asset.browserDownloadUrl + "?token=other", tag: tag, name: name))
    }

    @MainActor
    func testChecksumAndSizeVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertNoThrow(try UpdateService.verifyDownload(at: root, expectedSize: 3, sha256: digest))
        XCTAssertThrowsError(try UpdateService.verifyDownload(at: root, expectedSize: 4, sha256: digest))
        XCTAssertThrowsError(try UpdateService.verifyDownload(at: root, expectedSize: 3, sha256: String(repeating: "0", count: 64)))
    }

    @MainActor
    func testUpdateHandoffPreservesRollbackAndRestoresOnLaunchFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Yapper handoff \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for succeeds in [true, false] {
            let destination = root.appendingPathComponent("installed-\(succeeds)")
            let stage = root.appendingPathComponent("stage-\(succeeds)")
            let backup = root.appendingPathComponent("backup-\(succeeds)")
            try Data("old installation".utf8).write(to: destination)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: stage)
            let script = root.appendingPathComponent("handoff-\(succeeds).sh")
            try UpdateService.installScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, "2147483647", stage.path, destination.path, backup.path, succeeds ? "/usr/bin/true" : "/usr/bin/false"]
            try process.run(); process.waitUntilExit()
            if succeeds {
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old installation")
                XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")))
            } else {
                XCTAssertNotEqual(process.terminationStatus, 0)
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old installation")
            }
        }
    }

    @MainActor
    func testRealGitHubMetadataAndSignedPackageVerification() async throws {
        guard ProcessInfo.processInfo.environment["YAPPER_UPDATE_INTEGRATION"] == "1" else { throw XCTSkip("Opt-in release integrity test") }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/shishangia/yapper/releases/tags/v1.0.2")!)
        request.setValue("OpenAI File Downloader, XaiImageApiFetch/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let update = try AppVersion(from: JSONDecoder().decode(GitHubRelease.self, from: data))
        XCTAssertEqual(update.version, "1.0.2")
        let app = try XCTUnwrap(ProcessInfo.processInfo.environment["YAPPER_UPDATE_TEST_APP"])
        try UpdateService.verifyCandidateApp(at: URL(fileURLWithPath: app), version: update.version, build: update.buildNumber)
    }

    func testValidateSigningInfoAcceptsMatchingIdentity() {
        let signingInfo: [String: Any] = [
            kSecCodeInfoIdentifier as String: UpdateService.trustedUpdateBundleIdentifier,
            kSecCodeInfoTeamIdentifier as String: UpdateService.trustedUpdateTeamIdentifier,
        ]

        XCTAssertNoThrow(
            try UpdateService.validateSigningInfo(
                signingInfo,
                expectedBundleIdentifier: UpdateService.trustedUpdateBundleIdentifier,
                expectedTeamIdentifier: UpdateService.trustedUpdateTeamIdentifier
            )
        )
    }

    func testValidateSigningInfoRejectsUnexpectedBundleIdentifier() {
        let signingInfo: [String: Any] = [
            kSecCodeInfoIdentifier as String: "com.example.other",
            kSecCodeInfoTeamIdentifier as String: UpdateService.trustedUpdateTeamIdentifier,
        ]

        XCTAssertThrowsError(
            try UpdateService.validateSigningInfo(
                signingInfo,
                expectedBundleIdentifier: UpdateService.trustedUpdateBundleIdentifier,
                expectedTeamIdentifier: UpdateService.trustedUpdateTeamIdentifier
            )
        ) { error in
            guard case UpdateError.invalidCandidateApp = error else {
                return XCTFail("Expected invalidCandidateApp, got \(error)")
            }
        }
    }

    func testValidateSigningInfoRejectsUnexpectedTeamIdentifier() {
        let signingInfo: [String: Any] = [
            kSecCodeInfoIdentifier as String: UpdateService.trustedUpdateBundleIdentifier,
            kSecCodeInfoTeamIdentifier as String: "TEAM999999",
        ]

        XCTAssertThrowsError(
            try UpdateService.validateSigningInfo(
                signingInfo,
                expectedBundleIdentifier: UpdateService.trustedUpdateBundleIdentifier,
                expectedTeamIdentifier: UpdateService.trustedUpdateTeamIdentifier
            )
        ) { error in
            XCTAssertEqual(error as? UpdateError, .untrustedDeveloper)
        }
    }
}
