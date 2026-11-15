import Foundation

public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    public init() {}

    public func fetch() async throws -> ProviderSnapshot {
        let file = try HTTP.readHomeFile(".codex/auth.json", cli: id.cliName)
        let credentials = try Self.credentials(fromAuthFile: file)
        let data = try await HTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: ["Authorization": "Bearer \(credentials.accessToken)", "chatgpt-account-id": credentials.accountID],
            cli: id.cliName
        )
        return try Self.parse(data, now: Date())
    }

    /// Without `tokens` (e.g. Codex signed in with an API key, not ChatGPT) there are no
    /// subscription limits, so it counts as not signed in; an undecodable file is an error.
    static func credentials(fromAuthFile data: Data) throws -> (accessToken: String, accountID: String) {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String; let account_id: String }
            let tokens: Tokens?
        }
        let cli = ProviderID.codex.cliName
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data) else { throw UsageError.credentialsUnreadable(cli: cli) }
        guard let tokens = auth.tokens else { throw UsageError.notSignedIn(cli: cli) }
        return (tokens.access_token, tokens.account_id)
    }

    private struct Response: Decodable {
        struct Window: Decodable { let used_percent: Double; let limit_window_seconds: Int; let reset_at: Double? }
        struct RateLimit: Decodable { let primary_window: Window?; let secondary_window: Window? }
        let plan_type: String?
        let rate_limit: RateLimit?
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        let response = try decode(Response.self, from: data)
        let windows = [response.rate_limit?.primary_window, response.rate_limit?.secondary_window]
            .compactMap { $0 }
            .map { w in
                LimitWindow(
                    label: windowLabel(seconds: w.limit_window_seconds),
                    usedPercent: w.used_percent,
                    resetsAt: w.reset_at.map { Date(timeIntervalSince1970: $0) },
                    duration: TimeInterval(w.limit_window_seconds)
                )
            }
        return ProviderSnapshot(windows: windows, plan: response.plan_type, fetchedAt: now)
    }
}
