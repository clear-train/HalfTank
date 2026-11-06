import Foundation

/// Reads one prepaid balance with a user-supplied API key.
///
/// This is the only request HalfTank makes to a balance provider, and it happens
/// only when a key is configured. The endpoints need nothing else: no browser
/// session, no exported cookies.
actor BalanceClient {
    enum ClientError: Equatable, Error {
        case unauthorized
        case invalidPayload
        case requestFailed(Int)
    }

    private let source: BalanceSource
    private let endpoint: URL
    private let requestTimeout: TimeInterval
    private let session: URLSession

    init(
        source: BalanceSource,
        endpoint: URL? = nil,
        requestTimeout: TimeInterval = 20,
        session: URLSession = .shared
    ) {
        self.source = source
        self.endpoint = endpoint ?? source.endpoint
        self.requestTimeout = requestTimeout
        self.session = session
    }

    func fetch(apiKey: String, now: Date = Date()) async throws -> BalanceSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidPayload
        }
        switch http.statusCode {
        case 200:
            do {
                return try BalanceParser.parse(data, source: source, fetchedAt: now)
            } catch {
                throw ClientError.invalidPayload
            }
        case 401, 403:
            // A rejected key usually comes back as text or a provider-specific
            // error body, so the status code is the only signal worth trusting.
            throw ClientError.unauthorized
        default:
            throw ClientError.requestFailed(http.statusCode)
        }
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "HalfTank/\(version) (+https://github.com/clear-train/HalfTank)"
    }
}
