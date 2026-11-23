import Foundation

public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID.antigravity
    public init() {}

    private static let baseURL = "https://daily-cloudcode-pa.googleapis.com/v1internal"
    private static let userAgent = "antigravity/hub/2.24.0"
    private static let fiveHourDuration: TimeInterval = 18_000
    private static let weeklyDuration: TimeInterval = 604_800

    public func fetch() async throws -> ProviderSnapshot {
        let token = try await readCredentials()
        let headers = ["Authorization": "Bearer \(token)", "User-Agent": Self.userAgent]

        let loadBody = Data(#"{"metadata":{"ideType":"ANTIGRAVITY"}}"#.utf8)
        let loadData = try await HTTP.post(URL(string: "\(Self.baseURL):loadCodeAssist")!, body: loadBody, headers: headers, cli: id.cliName)
        let account = try Self.parseLoadCodeAssist(loadData)

        let summaryBody: Data
        if let project = account.project {
            summaryBody = try JSONEncoder().encode(["project": project])
        } else {
            summaryBody = Data("{}".utf8)
        }
        let summaryData = try await HTTP.post(URL(string: "\(Self.baseURL):retrieveUserQuotaSummary")!, body: summaryBody, headers: headers, cli: id.cliName)
        let snapshot = try Self.parseQuotaSummary(summaryData, now: Date())
        return ProviderSnapshot(windows: snapshot.windows, plan: account.plan, fetchedAt: snapshot.fetchedAt)
    }

    private func readCredentials() async throws -> String {
        let result = try await HTTP.readKeychainPassword(service: "gemini", account: "antigravity", cli: id.cliName)
        return try Self.credentials(fromSecurityOutput: result.output, status: result.status, timedOut: result.timedOut)
    }

    /// Maps the result of `security find-generic-password -s gemini -a antigravity -w` to an OAuth access token.
    /// `agy` stores credentials via `go-keyring`, which prefixes base64-encoded JSON with `go-keyring-base64:`.
    static func credentials(fromSecurityOutput output: Data, status: Int32, timedOut: Bool) throws -> String {
        let cli = ProviderID.antigravity.cliName
        if timedOut { throw UsageError.keychainTimeout }
        if status == 44 { throw UsageError.notSignedIn(cli: cli) }
        guard status == 0, let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw UsageError.credentialsUnreadable(cli: cli) }

        let jsonData: Data
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))) else {
                throw UsageError.credentialsUnreadable(cli: cli)
            }
            jsonData = decoded
        } else {
            jsonData = Data(text.utf8)
        }

        struct Credentials: Decodable {
            struct Token: Decodable { let access_token: String }
            let token: Token?
        }
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: jsonData)
        else { throw UsageError.credentialsUnreadable(cli: cli) }
        guard let accessToken = credentials.token?.access_token, !accessToken.isEmpty
        else { throw UsageError.notSignedIn(cli: cli) }
        return accessToken
    }

    private struct LoadCodeAssistResponse: Decodable {
        struct Tier: Decodable { let id: String?; let name: String? }
        let cloudaicompanionProject: String?
        let paidTier: Tier?
        let currentTier: Tier?
    }

    static func parseLoadCodeAssist(_ data: Data) throws -> (project: String?, plan: String?) {
        let response = try decode(LoadCodeAssistResponse.self, from: data)
        let tier = response.paidTier ?? response.currentTier
        return (response.cloudaicompanionProject, planName(for: tier))
    }

    private static func planName(for tier: LoadCodeAssistResponse.Tier?) -> String? {
        guard let tier else { return nil }
        switch tier.id {
        case "g1-pro-tier": return "pro"
        case "g1-ultra-tier": return "ultra"
        case "free-tier": return "free"
        case "standard-tier": return "standard"
        default: return tier.name?.isEmpty == false ? tier.name : nil
        }
    }

    private struct QuotaSummaryResponse: Decodable {
        struct Bucket: Decodable {
            let bucketId: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let isExhausted: Bool?
        }
        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }
        let groups: [Group]?
    }

    public static func parseQuotaSummary(_ data: Data, now: Date) throws -> ProviderSnapshot {
        let response = try decode(QuotaSummaryResponse.self, from: data)
        let groups = response.groups ?? []
        let mainGeminiGroup = groups.first { group in
            (group.buckets ?? []).contains { $0.bucketId == "gemini-weekly" || $0.bucketId == "gemini-5h" }
        } ?? groups.first { group in
            group.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gemini models"
        }

        guard let buckets = mainGeminiGroup?.buckets else {
            return ProviderSnapshot(windows: [], plan: nil, fetchedAt: now)
        }

        let weeklyBucket = buckets.first { $0.window?.lowercased() == "weekly" || $0.bucketId == "gemini-weekly" }
        let fiveHourBucket = buckets.first { $0.window?.lowercased() == "5h" || $0.bucketId == "gemini-5h" }

        var windows: [LimitWindow] = []
        if let weeklyBucket {
            windows.append(makeWindow(label: "Week", bucket: weeklyBucket, duration: Self.weeklyDuration))
        }
        if let fiveHourBucket {
            let fiveHour = makeWindow(label: "5h", bucket: fiveHourBucket, duration: Self.fiveHourDuration)
            if weeklyBucket == nil || shouldShowFiveHour(fiveHour, now: now) {
                windows.append(fiveHour)
            }
        }
        return ProviderSnapshot(windows: windows, plan: nil, fetchedAt: now)
    }

    static func shouldShowFiveHour(_ window: LimitWindow, now: Date) -> Bool {
        if window.usedPercent >= 80 { return true }
        guard window.usedPercent > 50, let pace = window.pacePercent(now: now) else { return false }
        return window.usedPercent - pace >= 20
    }

    private static func makeWindow(label: String, bucket: QuotaSummaryResponse.Bucket, duration: TimeInterval) -> LimitWindow {
        // In proto3 JSON, remainingFraction: 0 is omitted when a bucket is exhausted.
        let remaining = bucket.remainingFraction ?? (bucket.resetTime != nil || bucket.isExhausted == true ? 0 : 1)
        let usedPercent = min(max((1 - remaining) * 100, 0), 100)
        let resetsAt = bucket.resetTime.flatMap(parseISO8601)
        return LimitWindow(label: label, usedPercent: usedPercent, resetsAt: resetsAt, duration: duration)
    }
}
