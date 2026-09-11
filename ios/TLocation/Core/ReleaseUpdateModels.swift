import Foundation

struct PublishedAppVersion: Codable, Equatable, Sendable {
    let version: String
    let buildVersion: String
    let date: String
    let localizedDescription: String?
    let downloadURL: URL
    let size: Int
    let minOSVersion: String?

    var releaseDate: Date? {
        ISO8601DateFormatter().date(from: date)
    }
}

private struct UpdateSource: Decodable {
    struct App: Decodable {
        let bundleIdentifier: String
        let versions: [PublishedAppVersion]
    }

    let apps: [App]
}

enum UpdateCheckStatus: String, Equatable, Sendable {
    case upToDate
    case updateAvailable
    case checkFailed
    case unknown
}

struct UpdateCheckSnapshot: Equatable, Sendable {
    var status: UpdateCheckStatus
    var availableRelease: PublishedAppVersion?
    var lastSuccessfulCheck: Date?

    static let unknown = UpdateCheckSnapshot(
        status: .unknown,
        availableRelease: nil,
        lastSuccessfulCheck: nil
    )
}

enum UpdateManifestError: LocalizedError, Equatable {
    case missingApp(String)
    case noVersions
    case malformedVersion(String)

    var errorDescription: String? {
        switch self {
        case .missingApp(let bundleIdentifier):
            return "The update source does not contain \(bundleIdentifier)."
        case .noVersions:
            return "The update source contains no released versions."
        case .malformedVersion(let value):
            return "The update source contains an invalid version value: \(value)."
        }
    }
}

enum UpdateManifestParser {
    static func latestRelease(
        from data: Data,
        bundleIdentifier: String
    ) throws -> PublishedAppVersion {
        let source = try JSONDecoder().decode(UpdateSource.self, from: data)
        guard let app = source.apps.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw UpdateManifestError.missingApp(bundleIdentifier)
        }
        guard let release = app.versions.first else {
            throw UpdateManifestError.noVersions
        }
        guard VersionOrdering.components(release.version) != nil,
              VersionOrdering.components(release.buildVersion) != nil else {
            throw UpdateManifestError.malformedVersion(
                "\(release.version) (\(release.buildVersion))"
            )
        }
        return release
    }
}

enum VersionOrdering {
    static func components(_ value: String) -> [Int]? {
        let numeric = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let pieces = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        let result = pieces.compactMap { Int($0) }
        return result.count == pieces.count ? result : nil
    }

    static func isInstalledVersion(
        version installedVersion: String,
        build installedBuild: String,
        olderThan release: PublishedAppVersion
    ) -> Bool {
        guard let installedVersionParts = components(installedVersion),
              let releaseVersionParts = components(release.version),
              let installedBuildParts = components(installedBuild),
              let releaseBuildParts = components(release.buildVersion) else {
            return false
        }

        let marketingComparison = compare(installedVersionParts, releaseVersionParts)
        if marketingComparison != 0 { return marketingComparison < 0 }
        return compare(installedBuildParts, releaseBuildParts) < 0
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

enum UpdateCheckReducer {
    static func success(
        previous: UpdateCheckSnapshot,
        installedVersion: String,
        installedBuild: String,
        release: PublishedAppVersion,
        checkedAt: Date
    ) -> UpdateCheckSnapshot {
        let isAvailable = VersionOrdering.isInstalledVersion(
            version: installedVersion,
            build: installedBuild,
            olderThan: release
        )
        return UpdateCheckSnapshot(
            status: isAvailable ? .updateAvailable : .upToDate,
            availableRelease: isAvailable ? release : nil,
            lastSuccessfulCheck: checkedAt
        )
    }

    /// A failed request changes the current status but retains the last known
    /// release and successful timestamp. It cannot affect simulation startup.
    static func failure(previous: UpdateCheckSnapshot) -> UpdateCheckSnapshot {
        UpdateCheckSnapshot(
            status: .checkFailed,
            availableRelease: previous.availableRelease,
            lastSuccessfulCheck: previous.lastSuccessfulCheck
        )
    }
}

enum SideStoreURLBuilder {
    static func installURL(for ipaURL: URL) -> URL? {
        makeURL(host: "install", targetURL: ipaURL)
    }

    static func sourceURL(for sourceURL: URL) -> URL? {
        makeURL(host: "source", targetURL: sourceURL)
    }

    private static func makeURL(host: String, targetURL: URL) -> URL? {
        guard targetURL.scheme?.lowercased() == "https", targetURL.host != nil else { return nil }
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = host
        components.queryItems = [URLQueryItem(name: "url", value: targetURL.absoluteString)]
        return components.url
    }
}
