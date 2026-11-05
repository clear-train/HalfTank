import Foundation

/// Reads the DeepSeek platform balance with a user-supplied API key.
///
/// This is the only request HalfTank makes to DeepSeek, and it happens only when
/// a key is configured. The platform endpoint needs nothing else: no browser
/// session, no exported cookies.
actor DeepSeekClient {
    static let defaultEndpoint = URL(string: "https://api.deepseek.com/user/balance")!

    enum ClientError: Equatable, Error {
        case unauthorized
        case invalidPayload
        case requestFailed(Int)
    }

    private let endpoint: URL
    private let requestTimeout: TimeInterval
    private let session: URLSession

    init(
        endpoint: URL = DeepSeekClient.defaultEndpoint,
        requestTimeout: TimeInterval = 20,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
        self.session = session
    }

    func fetch(apiKey: String, now: Date = Date()) async throws -> DeepSeekBalanceSnapshot {
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
                return try DeepSeekBalanceParser.parse(data, fetchedAt: now)
            } catch {
                throw ClientError.invalidPayload
            }
        case 401, 403:
            // A rejected key comes back as plain text, so the status code is the
            // only signal worth trusting.
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
