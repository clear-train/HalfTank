import Foundation

/// Fetches the community reset estimate from the tracker's public JSON endpoint.
/// The request is anonymous: it carries no account, quota, or credential data.
actor ResetForecastClient {
    static let defaultEndpoint = URL(string: "https://pingreset.com/api/status")!
    /// Human-readable page opened from the popover; the JSON endpoint is not a
    /// useful destination for a click.
    static let pageURL = URL(string: "https://pingreset.com/en")!

    private let endpoint: URL
    private let requestTimeout: TimeInterval
    private let session: URLSession

    init(
        endpoint: URL = ResetForecastClient.defaultEndpoint,
        requestTimeout: TimeInterval = 15,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: ResetForecastRedirectGuard(), delegateQueue: nil)
    }

    func fetch(now: Date = Date()) async throws -> ResetForecast {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResetForecastError.invalidPayload
        }
        return try ResetForecastParser.parse(data, fetchedAt: now, sourceURL: endpoint)
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "CodexMeter/\(version) (+https://github.com/clear-train/CodexMeter)"
    }
}

/// Keep the tracker request on its published origin; a redirect would move an
/// otherwise harmless request somewhere the user did not opt into.
nonisolated private final class ResetForecastRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
