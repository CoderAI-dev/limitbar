import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    public init() {}

    public func fetch() async throws -> ProviderSnapshot {
        let (token, plan) = try await readCredentials()
        let data = try await HTTP.get(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"],
            cli: id.cliName
        )
        let snapshot = try Self.parse(data, now: Date())
        return ProviderSnapshot(windows: snapshot.windows, plan: plan, fetchedAt: snapshot.fetchedAt)
    }

    private func readCredentials() async throws -> (token: String, plan: String?) {
        // Use the `security` CLI rather than SecItem: it is already on the item's ACL, so there is no
        // prompt, whereas an ad-hoc-signed app would be re-prompted after every rebuild.
        let result = try await HTTP.readKeychainPassword(service: "Claude Code-credentials", cli: id.cliName)
        return try Self.credentials(fromSecurityOutput: result.output, status: result.status, timedOut: result.timedOut)
    }

    /// Maps the result of `security find-generic-password -w` to a token and plan.
    static func credentials(fromSecurityOutput output: Data, status: Int32, timedOut: Bool) throws -> (token: String, plan: String?) {
        let cli = ProviderID.claude.cliName
        if timedOut { throw UsageError.keychainTimeout }
        // `security` exits with 44 when the item does not exist, i.e. Claude Code is not signed in.
        if status == 44 { throw UsageError.notSignedIn(cli: cli) }
        struct Credentials: Decodable {
            struct OAuth: Decodable { let accessToken: String; let subscriptionType: String? }
            let claudeAiOauth: OAuth?
        }
        guard status == 0, let credentials = try? JSONDecoder().decode(Credentials.self, from: output)
        else { throw UsageError.credentialsUnreadable(cli: cli) }
        // An item without a subscription login (API-key use, MCP OAuth data only) is not signed in.
        guard let oauth = credentials.claudeAiOauth else { throw UsageError.notSignedIn(cli: cli) }
        return (oauth.accessToken, oauth.subscriptionType)
    }

    private struct Response: Decodable {
        struct Window: Decodable { let utilization: Double; let resets_at: String? }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let group: String?
            let percent: Double
            let resets_at: String?
            let scope: Scope?
        }
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        let response = try decode(Response.self, from: data)
        var windows: [LimitWindow] = []
        if let w = response.five_hour {
            windows.append(LimitWindow(label: "5h", usedPercent: w.utilization, resetsAt: w.resets_at.flatMap(parseISO8601), duration: 18_000))
        }
        if let w = response.seven_day {
            windows.append(LimitWindow(label: "Week", usedPercent: w.utilization, resetsAt: w.resets_at.flatMap(parseISO8601), duration: 604_800))
        }
        for limit in response.limits ?? [] {
            guard let model = limit.scope?.model?.display_name else { continue }
            let weekly = limit.group == "weekly"
            let label = weekly ? "Week" : limit.group ?? "Limit"
            // Only weekly limits have a known length; others get no pace tick.
            windows.append(LimitWindow(label: "\(label) · \(model)", usedPercent: limit.percent,
                                       resetsAt: limit.resets_at.flatMap(parseISO8601), duration: weekly ? 604_800 : nil))
        }
        return ProviderSnapshot(windows: windows, plan: nil, fetchedAt: now)
    }
}
