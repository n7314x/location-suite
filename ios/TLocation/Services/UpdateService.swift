import Foundation

@MainActor
final class UpdateService: ObservableObject {
    private struct CachedCheck: Codable {
        let release: PublishedAppVersion
        let checkedAt: Date
    }

    static let shared = UpdateService()
    static let automaticCheckInterval: TimeInterval = 6 * 60 * 60
    static let requestTimeout: TimeInterval = 5

    @Published private(set) var snapshot: UpdateCheckSnapshot
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let session: URLSession

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: configuration)
        }

        if let cached = Self.loadCache(from: defaults) {
            snapshot = UpdateCheckReducer.success(
                previous: .unknown,
                installedVersion: Self.installedVersion,
                installedBuild: Self.installedBuild,
                release: cached.release,
                checkedAt: cached.checkedAt
            )
        } else {
            snapshot = .unknown
        }
    }

    var sourceURL: URL? { Self.configuredSourceURL }

    func checkIfNeeded(force: Bool = false, now: Date = Date()) async {
        guard !isChecking else { return }
        if !force,
           let lastSuccessfulCheck = snapshot.lastSuccessfulCheck,
           now.timeIntervalSince(lastSuccessfulCheck) < Self.automaticCheckInterval {
            return
        }
        guard let sourceURL else {
            lastError = "No public Location Suite update source is configured for this build."
            snapshot = UpdateCheckReducer.failure(previous: snapshot)
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: sourceURL)
            request.timeoutInterval = Self.requestTimeout
            request.cachePolicy = .reloadRevalidatingCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard data.count <= 512 * 1024 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            let release = try UpdateManifestParser.latestRelease(
                from: data,
                bundleIdentifier: Self.bundleIdentifier
            )
            snapshot = UpdateCheckReducer.success(
                previous: snapshot,
                installedVersion: Self.installedVersion,
                installedBuild: Self.installedBuild,
                release: release,
                checkedAt: now
            )
            lastError = nil
            Self.store(CachedCheck(release: release, checkedAt: now), in: defaults)
        } catch {
            snapshot = UpdateCheckReducer.failure(previous: snapshot)
            lastError = error.localizedDescription
        }
    }

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "vn.truongkma.tlocation"
    }

    private static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private static var configuredSourceURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LocationSuiteSourceURL") as? String,
              !value.isEmpty,
              !value.contains("$("),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func loadCache(from defaults: UserDefaults) -> CachedCheck? {
        guard let data = defaults.data(forKey: UserDefaults.Keys.updateCheckCache) else { return nil }
        return try? JSONDecoder().decode(CachedCheck.self, from: data)
    }

    private static func store(_ cached: CachedCheck, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        defaults.set(data, forKey: UserDefaults.Keys.updateCheckCache)
    }
}
