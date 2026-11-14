import Foundation

public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    public init() {}

    public func fetch() async throws -> ProviderSnapshot {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String; let account_id: String }
            let tokens: Tokens
        }
        let file = try HTTP.readHomeFile(".codex/auth.json", cli: id.cliName)
        guard let auth = try? JSONDecoder().decode(Auth.self, from: file) else { throw UsageError.notSignedIn(cli: id.cliName) }
        let data = try await HTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: ["Authorization": "Bearer \(auth.tokens.access_token)", "chatgpt-account-id": auth.tokens.account_id],
            cli: id.cliName
        )
        return try Self.parse(data, now: Date())
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
