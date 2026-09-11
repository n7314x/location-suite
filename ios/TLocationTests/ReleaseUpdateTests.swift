import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import LocationSuiteCore
#else
@testable import TLocation
#endif

private func release(
    version: String = "1.5.0",
    build: String = "15",
    url: String = "https://releases.example.test/location-suite/v1.5.0/LocationSuite.ipa"
) -> PublishedAppVersion {
    PublishedAppVersion(
        version: version,
        buildVersion: build,
        date: "2026-09-10T12:00:00Z",
        localizedDescription: "Diagnostics",
        downloadURL: URL(string: url)!,
        size: 123,
        minOSVersion: "17.4"
    )
}

struct UpdateComparisonTests {
    @Test func installedOldVersionReportsUpdateAvailable() {
        let result = UpdateCheckReducer.success(
            previous: .unknown,
            installedVersion: "1.4.3",
            installedBuild: "14",
            release: release(),
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(result.status == .updateAvailable)
        #expect(result.availableRelease == release())
    }

    @Test func sameVersionAndBuildReportsUpToDate() {
        let result = UpdateCheckReducer.success(
            previous: .unknown,
            installedVersion: "1.5.0",
            installedBuild: "15",
            release: release(),
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(result.status == .upToDate)
        #expect(result.availableRelease == nil)
    }

    @Test func newerBuildOfSameVersionReportsUpdateAvailable() {
        #expect(VersionOrdering.isInstalledVersion(
            version: "1.5.0",
            build: "15",
            olderThan: release(version: "1.5.0", build: "16")
        ))
    }

    @Test func malformedManifestFailsWithoutAffectingTheApp() {
        let data = Data(#"{"apps":[{"bundleIdentifier":"vn.truongkma.tlocation","versions":[{"version":"bad","buildVersion":"1","date":"2026-09-10","downloadURL":"https://example.test/app.ipa","size":1}]}]}"#.utf8)
        #expect(throws: UpdateManifestError.self) {
            try UpdateManifestParser.latestRelease(
                from: data,
                bundleIdentifier: "vn.truongkma.tlocation"
            )
        }
    }

    @Test func networkFailurePreservesCachedReleaseAndTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = UpdateCheckSnapshot(
            status: .updateAvailable,
            availableRelease: release(),
            lastSuccessfulCheck: timestamp
        )
        let failed = UpdateCheckReducer.failure(previous: previous)
        #expect(failed.status == .checkFailed)
        #expect(failed.availableRelease == previous.availableRelease)
        #expect(failed.lastSuccessfulCheck == timestamp)
    }
}

struct SideStoreURLTests {
    @Test func sourceAndInstallURLsEncodeTheNestedURL() throws {
        let ipa = URL(string: "https://example.test/v1.5.0/LocationSuite.ipa?token=a b")!
        let source = URL(string: "https://example.test/source.json")!
        let installLink = try #require(SideStoreURLBuilder.installURL(for: ipa))
        let sourceLink = try #require(SideStoreURLBuilder.sourceURL(for: source))

        #expect(installLink.scheme == "sidestore")
        #expect(installLink.host == "install")
        #expect(URLComponents(url: installLink, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == ipa.absoluteString)
        #expect(sourceLink.host == "source")
        #expect(URLComponents(url: sourceLink, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == source.absoluteString)
    }

    @Test func nonHTTPSInstallURLIsRejected() {
        #expect(SideStoreURLBuilder.installURL(for: URL(string: "file:///tmp/app.ipa")!) == nil)
    }
}

struct SigningExpiryPolicyTests {
    @Test func warningThresholdsEscalateAt72Hours48HoursAnd24Hours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checkedAt = now.addingTimeInterval(-60)
        let severity: (TimeInterval) -> SigningExpirySeverity = { remaining in
            SigningExpiryPolicy.severity(
                expirationDate: now.addingTimeInterval(remaining),
                checkedAt: checkedAt,
                now: now,
                trustWindow: 6 * 60 * 60
            )
        }

        #expect(severity(73 * 60 * 60) == .normal)
        #expect(severity(72 * 60 * 60) == .subtleWarning)
        #expect(severity(48 * 60 * 60) == .clearWarning)
        #expect(severity(24 * 60 * 60) == .urgentWarning)
        #expect(severity(-1) == .expired)
    }

    @Test func staleExpiryLookupCannotFalselyMarkExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SigningExpiryPolicy.severity(
            expirationDate: now.addingTimeInterval(-86_400),
            checkedAt: now.addingTimeInterval(-7 * 60 * 60),
            now: now,
            trustWindow: 6 * 60 * 60
        ) == .unknown)
    }
}
