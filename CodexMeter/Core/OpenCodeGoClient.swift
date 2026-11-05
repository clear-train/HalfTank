import Foundation

/// Which transport OpenCode Go usage should prefer.
enum OpenCodeGoChannel: String, CaseIterable, Codable, Sendable {
    /// Shell out to `opencode api`. OpenCode owns the session and refreshes an
    /// expired access token itself, so this path self-heals after long idle gaps.
    case cli
    /// Call the quota endpoint directly with the stored credential. Much faster,
    /// but requires a still-valid token because refreshing it here would rotate
    /// OpenCode's own refresh token.
    case direct
}

enum OpenCodeGoClientError: Error, Equatable {
    case executableNotFound
    case commandFailed(Int32)
    case commandTimedOut
    case unauthorized
    case notSubscribed
    case invalidPayload
    case requestFailed(Int)

    /// Locally authored, user-facing summary. Raw process and server output is
    /// never surfaced because it can contain tokens or account details.
    var localizationKey: String {
        switch self {
        case .executableNotFound: "error.opencode.not_installed"
        case .commandFailed, .commandTimedOut, .requestFailed, .invalidPayload:
            "error.opencode.usage_unavailable"
        case .unauthorized: "error.opencode.signed_out"
        case .notSubscribed: "error.opencode.no_subscription"
        }
    }
}

/// Reads OpenCode Go quota through the official CLI or the console API.
///
/// Both transports produce the same snapshot type. The CLI path is authoritative
/// and preferred; the direct path exists so a routine refresh costs one HTTP
/// request instead of launching a second Bun runtime.
actor OpenCodeGoClient {
    private let executableURL: URL?
    private let dataDirectory: URL
    private let channel: OpenCodeGoChannel
    private let commandTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let urlSession: URLSession

    init(
        executableURL: URL? = OpenCodeGoClient.locateExecutable(),
        dataDirectory: URL = OpenCodeGoCredentialStore.defaultDataDirectory(),
        channel: OpenCodeGoChannel = .cli,
        commandTimeout: TimeInterval = 25,
        requestTimeout: TimeInterval = 20,
        urlSession: URLSession = .shared
    ) {
        self.executableURL = executableURL
        self.dataDirectory = dataDirectory
        self.channel = channel
        self.commandTimeout = commandTimeout
        self.requestTimeout = requestTimeout
        self.urlSession = urlSession
    }

    static func locateExecutable(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        CodexExecutableLocator.locate(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            systemCandidateURLs: [
                URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
                URL(fileURLWithPath: "/usr/local/bin/opencode")
            ]
        )
    }

    func credential() -> OpenCodeGoCredential? {
        OpenCodeGoCredentialStore.load(dataDirectory: dataDirectory)
    }

    /// Fetches usage with an automatic fallback so one broken transport does not
    /// blank the menu bar.
    func fetchUsage(now: Date = Date()) async throws -> OpenCodeGoUsageSnapshot {
        switch channel {
        case .cli:
            do {
                return try await fetchThroughCommand(now: now)
            } catch {
                return try await fetchDirect(now: now)
            }
        case .direct:
            do {
                return try await fetchDirect(now: now)
            } catch {
                return try await fetchThroughCommand(now: now)
            }
        }
    }

    private func fetchThroughCommand(now: Date) async throws -> OpenCodeGoUsageSnapshot {
        guard let executableURL else { throw OpenCodeGoClientError.executableNotFound }
        let data = try runCommand(
            executableURL: executableURL,
            arguments: ["api", "--standalone", "experimental.usage.limits"]
        )
        do {
            return try OpenCodeGoUsageParser.parseCommandPayload(data, fetchedAt: now)
        } catch OpenCodeGoUsageError.notSubscribed {
            throw OpenCodeGoClientError.notSubscribed
        } catch {
            throw OpenCodeGoClientError.invalidPayload
        }
    }

    private func fetchDirect(now: Date) async throws -> OpenCodeGoUsageSnapshot {
        guard let credential = credential(), !credential.isExpired else {
            throw OpenCodeGoClientError.unauthorized
        }
        guard var components = URLComponents(url: credential.server, resolvingAgainstBaseURL: false) else {
            throw OpenCodeGoClientError.invalidPayload
        }
        components.path = "/zen/go/v1/usage"
        components.query = nil
        guard let url = components.url else { throw OpenCodeGoClientError.invalidPayload }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let organizationID = credential.organizationID {
            request.setValue(organizationID, forHTTPHeaderField: "x-opencode-org-id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeGoClientError.invalidPayload
        }
        switch http.statusCode {
        case 200:
            do {
                return try OpenCodeGoUsageParser.parseDirectPayload(data, fetchedAt: now)
            } catch {
                throw OpenCodeGoClientError.invalidPayload
            }
        case 401:
            throw OpenCodeGoClientError.unauthorized
        case 403:
            throw OpenCodeGoClientError.notSubscribed
        default:
            throw OpenCodeGoClientError.requestFailed(http.statusCode)
        }
    }

    private func runCommand(executableURL: URL, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = CodexProcessEnvironment.make(
            baseEnvironment: ProcessInfo.processInfo.environment,
            executableURL: executableURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            throw OpenCodeGoClientError.executableNotFound
        }

        let deadline = DispatchTime.now() + commandTimeout
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            // `terminate()` reports SIGTERM as a signal, not a small exit code.
            if process.terminationReason == .uncaughtSignal {
                throw OpenCodeGoClientError.commandTimedOut
            }
            let stdout = String(decoding: data, as: UTF8.self)
            if stdout.contains("Unauthorized") || stdout.contains("InvalidGrant") {
                throw OpenCodeGoClientError.unauthorized
            }
            throw OpenCodeGoClientError.commandFailed(process.terminationStatus)
        }
        return data
    }
}
