import Foundation

struct AppVersion: Codable, Equatable {
    let version: String
    let buildNumber: String
    let releaseNotes: [String]
    let downloadURL: String
    let isRequired: Bool
    let releaseDate: Date
    var sha256: String? = nil
    var downloadSize: Int64? = nil

    static func isNewerVersion(_ newVersion: String, than currentVersion: String) -> Bool {
        newVersion.compare(currentVersion, options: .numeric) == .orderedDescending
    }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var currentBuildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    init(from release: GitHubRelease) throws {
        guard !release.draft, !release.prerelease,
              release.tagName.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { throw UpdateError.verificationFailed }
        let clean = String(release.tagName.dropFirst())
        let candidates = release.assets.filter {
            $0.name.range(of: "^Yapper-\(NSRegularExpression.escapedPattern(for: clean))-[0-9]+-arm64\\.dmg$", options: .regularExpression) != nil
        }
        guard candidates.count == 1, let asset = candidates.first,
              Self.isTrustedDownload(asset.browserDownloadUrl, tag: release.tagName, name: asset.name),
              let digest = asset.digest, digest.range(of: #"^sha256:[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
              let size = asset.size, size > 0, size <= 2_000_000_000 else { throw UpdateError.verificationFailed }
        version = clean
        buildNumber = asset.name.components(separatedBy: "-").dropLast().last ?? "0"
        releaseNotes = release.body.components(separatedBy: "\n").filter { !$0.isEmpty }
        downloadURL = asset.browserDownloadUrl
        sha256 = String(digest.dropFirst(7)).lowercased()
        downloadSize = size
        isRequired = false
        releaseDate = ISO8601DateFormatter().date(from: release.publishedAt) ?? Date()
    }

    static func isTrustedDownload(_ value: String, tag: String, name: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path == "/shishangia/yapper/releases/download/\(tag)/\(name)"
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    let digest: String?
    let size: Int64?
    enum CodingKeys: String, CodingKey {
        case name, digest, size
        case browserDownloadUrl = "browser_download_url"
    }
}
struct GitHubRelease: Codable {
    let tagName: String
    let body: String
    let htmlUrl: String
    let publishedAt: String
    let assets: [GitHubAsset]
    let draft: Bool
    let prerelease: Bool
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets, draft, prerelease
    }
}

extension AppVersion {
    static let mockUpdate = try! AppVersion(from: GitHubRelease(tagName: "v1.0.4", body: "Improved recording and update controls.",
        htmlUrl: "https://github.com/shishangia/yapper/releases/tag/v1.0.4", publishedAt: "2026-09-19T00:00:00Z",
        assets: [.init(name: "Yapper-1.0.4-8-arm64.dmg", browserDownloadUrl: "https://github.com/shishangia/yapper/releases/download/v1.0.4/Yapper-1.0.4-8-arm64.dmg", digest: "sha256:" + String(repeating: "a", count: 64), size: 100)], draft: false, prerelease: false))
}
