import Foundation

public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID.antigravity
    public init() {}

    private static let baseURL = "https://daily-cloudcode-pa.googleapis.com/v1internal"
    private static let userAgent = "antigravity/1.0"

    public func fetch() async throws -> ProviderSnapshot {
        let token = try await readCredentials()
        let headers = ["Authorization": "Bearer \(token)", "User-Agent": Self.userAgent]

        let loadBody = Data(#"{"metadata":{"ideType":"ANTIGRAVITY"}}"#.utf8)
        let loadData = try await HTTP.post(URL(string: "\(Self.baseURL):loadCodeAssist")!, body: loadBody, headers: headers, cli: id.cliName)
        let account = try Self.parseLoadCodeAssist(loadData)

        let modelsBody: Data
        if let project = account.project {
            modelsBody = try JSONEncoder().encode(["project": project])
        } else {
            modelsBody = Data("{}".utf8)
        }
        let modelsData = try await HTTP.post(URL(string: "\(Self.baseURL):fetchAvailableModels")!, body: modelsBody, headers: headers, cli: id.cliName)
        let snapshot = try Self.parseModels(modelsData, now: Date())
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

    private struct ModelsResponse: Decodable {
        struct QuotaInfo: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
            let isExhausted: Bool?
        }
        struct Model: Decodable {
            let isInternal: Bool?
            let recommended: Bool?
            let modelProvider: String?
            let quotaInfo: QuotaInfo?
        }
        let models: [String: Model]?
    }

    private enum Bucket {
        case geminiPro, geminiFlash, claude, gpt
    }

    private struct BucketQuota {
        var usedPercent: Double
        var resetsAt: Date?

        mutating func merge(usedPercent: Double, resetsAt: Date?) {
            if usedPercent > self.usedPercent {
                self.usedPercent = usedPercent
            }
            if let resetsAt, self.resetsAt.map({ resetsAt < $0 }) ?? true {
                self.resetsAt = resetsAt
            }
        }

        func matches(_ other: BucketQuota) -> Bool {
            abs(usedPercent - other.usedPercent) < 0.01 && resetsAt == other.resetsAt
        }
    }

    public static func parseModels(_ data: Data, now: Date) throws -> ProviderSnapshot {
        let response = try decode(ModelsResponse.self, from: data)
        let allModels = (response.models ?? [:]).filter { id, model in
            model.isInternal != true && model.quotaInfo != nil && !id.hasPrefix("tab_")
        }
        let hasRecommended = allModels.values.contains { $0.recommended == true }
        let eligible = allModels.filter { _, model in
            if hasRecommended {
                return model.recommended == true
            }
            return model.quotaInfo?.resetTime != nil || model.quotaInfo?.isExhausted == true
        }

        var buckets: [Bucket: BucketQuota] = [:]
        for (modelID, model) in eligible {
            guard let quota = model.quotaInfo else { continue }
            guard let bucket = classify(modelID: modelID, provider: model.modelProvider) else { continue }
            // In proto3 JSON, remainingFraction: 0 is omitted when a bucket is exhausted.
            let remaining = quota.remainingFraction ?? (quota.resetTime != nil || quota.isExhausted == true ? 0 : 1)
            let usedPercent = min(max((1 - remaining) * 100, 0), 100)
            let resetsAt = quota.resetTime.flatMap(parseISO8601)
            if var existing = buckets[bucket] {
                existing.merge(usedPercent: usedPercent, resetsAt: resetsAt)
                buckets[bucket] = existing
            } else {
                buckets[bucket] = BucketQuota(usedPercent: usedPercent, resetsAt: resetsAt)
            }
        }

        var windows: [LimitWindow] = []
        appendGroup(
            first: (.geminiPro, "Gemini Pro"),
            second: (.geminiFlash, "Gemini Flash"),
            mergedLabel: "Gemini",
            singleUsesMerged: true,
            from: buckets,
            now: now,
            into: &windows
        )
        appendGroup(
            first: (.claude, "Claude"),
            second: (.gpt, "GPT"),
            mergedLabel: "Claude · GPT",
            singleUsesMerged: false,
            from: buckets,
            now: now,
            into: &windows
        )
        return ProviderSnapshot(windows: windows, plan: nil, fetchedAt: now)
    }

    private static func classify(modelID: String, provider: String?) -> Bucket? {
        let lower = modelID.lowercased()
        if provider == "MODEL_PROVIDER_GOOGLE" || lower.hasPrefix("gemini") {
            return lower.contains("flash") ? .geminiFlash : .geminiPro
        }
        if provider == "MODEL_PROVIDER_ANTHROPIC" || lower.hasPrefix("claude") {
            return .claude
        }
        if provider == "MODEL_PROVIDER_OPENAI" || lower.hasPrefix("gpt") {
            return .gpt
        }
        return nil
    }

    private static func appendGroup(
        first: (Bucket, String),
        second: (Bucket, String),
        mergedLabel: String,
        singleUsesMerged: Bool,
        from buckets: [Bucket: BucketQuota],
        now: Date,
        into windows: inout [LimitWindow]
    ) {
        switch (buckets[first.0], buckets[second.0]) {
        case let (a?, b?) where a.matches(b):
            windows.append(makeWindow(label: mergedLabel, quota: a, now: now))
        case let (a?, b?):
            windows.append(makeWindow(label: first.1, quota: a, now: now))
            windows.append(makeWindow(label: second.1, quota: b, now: now))
        case let (a?, nil):
            windows.append(makeWindow(label: singleUsesMerged ? mergedLabel : first.1, quota: a, now: now))
        case let (nil, b?):
            windows.append(makeWindow(label: singleUsesMerged ? mergedLabel : second.1, quota: b, now: now))
        case (nil, nil):
            break
        }
    }

    private static func makeWindow(label: String, quota: BucketQuota, now: Date) -> LimitWindow {
        let duration: TimeInterval? = quota.resetsAt.flatMap { resetsAt in
            let remaining = resetsAt.timeIntervalSince(now)
            if remaining <= 18_000 + 300 { return 18_000 }
            if remaining <= 604_800 + 300 { return 604_800 }
            return nil
        }
        return LimitWindow(label: label, usedPercent: quota.usedPercent, resetsAt: quota.resetsAt, duration: duration)
    }
}
