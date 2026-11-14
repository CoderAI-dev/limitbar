import Foundation

public struct GrokProvider: UsageProvider {
    public let id = ProviderID.grok
    public init() {}

    public func fetch() async throws -> ProviderSnapshot {
        let file = try HTTP.readHomeFile(".grok/auth.json", cli: id.cliName)
        guard let key = Self.bearerKey(fromAuthFile: file) else { throw UsageError.notSignedIn(cli: id.cliName) }
        let data = try await HTTP.get(
            URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
            headers: ["Authorization": "Bearer \(key)"],
            cli: id.cliName
        )
        return try Self.parse(data, now: Date())
    }

    /// The auth file is keyed by `<issuer>::<id>`. Only x.ai-issued tokens are sent to the endpoint;
    /// the first such entry with a string `key` holds the token.
    static func bearerKey(fromAuthFile data: Data) -> String? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return entries.keys.filter { $0.hasPrefix("https://auth.x.ai::") }.sorted().lazy
            .compactMap { (entries[$0] as? [String: Any])?["key"] as? String }.first
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
