import Foundation

public enum AnimeHeavenClientError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case httpError(statusCode: Int, url: String)
    case emptyBody(String)
    case unableToResolveRandomId

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw): return "Invalid URL: \(raw)"
        case .httpError(let code, let url): return "HTTP \(code) for \(url)"
        case .emptyBody(let url): return "Empty response body for \(url)"
        case .unableToResolveRandomId: return "Unable to resolve random anime ID"
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class SiteRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(AnimeHeavenClient.isSiteURL) == true ? request : nil)
    }
}

public final class AnimeHeavenClient: Sendable {
    public static let baseURL = "https://animeheaven.me"
    public static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    public let session: URLSession
    private let noRedirectSession: URLSession
    private let siteRedirectDelegate = SiteRedirectDelegate()

    public init(session: URLSession? = nil) {
        let configured = session ?? Self.makeDefaultSession()
        self.session = configured
        let delegate = NoRedirectDelegate()

        let noRedirectConfig = URLSessionConfiguration.ephemeral
        noRedirectConfig.timeoutIntervalForRequest = 8
        noRedirectConfig.timeoutIntervalForResource = 12
        noRedirectConfig.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.noRedirectSession = URLSession(
            configuration: noRedirectConfig,
            delegate: delegate,
            delegateQueue: nil
        )
    }
    deinit { noRedirectSession.invalidateAndCancel() }

    fileprivate static func isSiteURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "animeheaven.me" &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public static func makeDefaultSession(cacheDirectory: URL? = nil) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 18
        config.httpMaximumConnectionsPerHost = 12
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        if let cacheDir = cacheDirectory {
            let httpCacheDir = cacheDir.appendingPathComponent("http_cache", isDirectory: true)
            config.urlCache = URLCache(
                memoryCapacity: 4 * 1024 * 1024,
                diskCapacity: 24 * 1024 * 1024,
                directory: httpCacheDir
            )
        } else {
            config.urlCache = URLCache(
                memoryCapacity: 4 * 1024 * 1024,
                diskCapacity: 24 * 1024 * 1024
            )
        }
        return URLSession(configuration: config)
    }

    public func fetchHtml(relativePath: String) async throws -> String {
        guard let url = URL(string: relativePath, relativeTo: URL(string: "\(Self.baseURL)/"))?.absoluteURL,
              Self.isSiteURL(url) else {
            throw AnimeHeavenClientError.invalidURL(relativePath)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        return try await executeForString(request)
    }

    public func fetchFastSearch(query: String) async throws -> String {
        let encoded = Self.urlQueryEncode(query)
        let urlString = "\(Self.baseURL)/fastsearch.php?xhr=1&s=\(encoded)"
        guard let url = URL(string: urlString) else {
            throw AnimeHeavenClientError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(Self.baseURL)/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        return try await executeForString(request)
    }

    public func fetchRandomAnimeId() async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/random.php") else {
            throw AnimeHeavenClientError.invalidURL("\(Self.baseURL)/random.php")
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(Self.baseURL)/", forHTTPHeaderField: "Referer")

        if let (_, resp) = try? await noRedirectSession.data(for: request),
           let http = resp as? HTTPURLResponse,
           let location = http.value(forHTTPHeaderField: "Location"),
           let destination = URL(string: location, relativeTo: url)?.absoluteURL, Self.isSiteURL(destination),
           let fromLocation = AnimeHeavenParser.extractAnimeId(destination.absoluteString),
           !fromLocation.isEmpty {
            return fromLocation
        }

        try Task.checkCancellation()
        let (_, resp) = try await session.data(for: request, delegate: siteRedirectDelegate)
        if let finalURL = resp.url?.absoluteString,
           let fromFinal = AnimeHeavenParser.extractAnimeId(finalURL),
           !fromFinal.isEmpty {
            return fromFinal
        }
        throw AnimeHeavenClientError.unableToResolveRandomId
    }

    public func fetchGateHtml(episodeKey: String, animeId: String?) async throws -> String {
        guard Self.isValidIdentifier(episodeKey),
              animeId.map({ $0.isEmpty || Self.isValidIdentifier($0) }) ?? true else {
            throw AnimeHeavenClientError.invalidURL("Invalid anime or episode identifier")
        }
        guard let url = URL(string: "\(Self.baseURL)/gate.php") else {
            throw AnimeHeavenClientError.invalidURL("\(Self.baseURL)/gate.php")
        }
        let referer: String
        if let animeId, !animeId.isEmpty {
            referer = "\(Self.baseURL)/anime.php?\(animeId)"
        } else {
            referer = "\(Self.baseURL)/"
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("key=\(episodeKey)", forHTTPHeaderField: "Cookie")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        return try await executeForString(request)
    }

    public func preconnectHosts(_ urls: [String] = [AnimeHeavenClient.baseURL]) {
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 4
            request.cachePolicy = .reloadIgnoringLocalCacheData
            Task.detached(priority: .utility) { [session] in
                _ = try? await session.data(for: request)
            }
        }
    }

    private func executeForString(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request, delegate: siteRedirectDelegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnimeHeavenClientError.httpError(
                statusCode: http.statusCode,
                url: request.url?.absoluteString ?? ""
            )
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw AnimeHeavenClientError.emptyBody(request.url?.absoluteString ?? "")
        }
        return text
    }

    public static func urlQueryEncode(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/#")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
