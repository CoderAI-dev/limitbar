import Foundation

public struct GrokProvider: UsageProvider {
    public let id = ProviderID.grok
    public init() {}

    public func fetch() async throws -> ProviderSnapshot {
        let file = try HTTP.readHomeFile(".grok/auth.json", cli: id.cliName)
        guard let key = try Self.bearerKey(fromAuthFile: file) else { throw UsageError.notSignedIn(cli: id.cliName) }
        let headers = ["Authorization": "Bearer \(key)"]
        async let billingData = HTTP.get(
            URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
            headers: headers,
            cli: id.cliName
        )
        async let settingsData = try? HTTP.get(
            URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
            headers: headers,
            cli: id.cliName
        )
        let snapshot = try Self.parse(try await billingData, now: Date())
        let plan = await settingsData.flatMap(Self.parsePlan)
        return ProviderSnapshot(windows: snapshot.windows, plan: plan, fetchedAt: snapshot.fetchedAt)
    }

    /// The auth file is keyed by `<issuer>::<id>`. Only x.ai-issued tokens are sent to the endpoint;
    /// the first such entry with a string `key` holds the token. Returns nil when there is no x.ai
    /// entry (not signed in); throws when the file or its x.ai entries are not in the expected shape.
    static func bearerKey(fromAuthFile data: Data) throws -> String? {
        let unreadable = UsageError.credentialsUnreadable(cli: ProviderID.grok.cliName)
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unreadable }
        let issuerKeys = entries.keys.filter { $0.hasPrefix("https://auth.x.ai::") }.sorted()
        if issuerKeys.isEmpty { return nil }
        guard let key = issuerKeys.lazy.compactMap({ (entries[$0] as? [String: Any])?["key"] as? String }).first
        else { throw unreadable }
        return key
    }

    private struct SettingsResponse: Decodable {
        let subscription_tier_display: String?
        let subscription_tier: String?
    }

    static func parsePlan(_ data: Data) -> String? {
        guard let settings = try? JSONDecoder().decode(SettingsResponse.self, from: data) else { return nil }
        return [settings.subscription_tier_display, settings.subscription_tier]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private struct Response: Decodable {
        struct Config: Decodable {
            struct Period: Decodable { let type: String?; let start: String?; let end: String? }
            let currentPeriod: Period?
            let creditUsagePercent: Double
        }
        let config: Config
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        let config = try decode(Response.self, from: data).config
        let label = switch config.currentPeriod?.type {
        case "USAGE_PERIOD_TYPE_WEEKLY": "Week"
        case "USAGE_PERIOD_TYPE_MONTHLY": "Month"
        default: "Period"
        }
        let start = config.currentPeriod?.start.flatMap(parseISO8601)
        let end = config.currentPeriod?.end.flatMap(parseISO8601)
        let duration = if let start, let end { end.timeIntervalSince(start) } else { TimeInterval?.none }
        let window = LimitWindow(label: label, usedPercent: config.creditUsagePercent, resetsAt: end, duration: duration)
        return ProviderSnapshot(windows: [window], plan: nil, fetchedAt: now)
    }
}
