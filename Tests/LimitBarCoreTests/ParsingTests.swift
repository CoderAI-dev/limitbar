import Foundation
import Testing
@testable import LimitBarCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite struct ClaudeParsingTests {
    @Test func nullFiveHourWithScopedLimit() throws {
        let data = json("""
        {"five_hour":null,"extra":{"x":1},
         "seven_day":{"utilization":19.0,"resets_at":"2026-11-21T03:00:00.058322+00:00"},
         "limits":[
          {"kind":"weekly_all","group":"weekly","percent":19,"severity":"normal","resets_at":"2026-11-21T03:00:00.058322+00:00","scope":null,"is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":35,"severity":"normal","resets_at":"2026-11-21T03:00:00.058478+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}
        """)
        let snapshot = try ClaudeProvider.parse(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["Week", "Week · Fable"])
        #expect(snapshot.windows.map(\.usedPercent) == [19, 35])
        #expect(snapshot.windows[0].resetsAt == parseISO8601("2026-11-21T03:00:00Z")!.addingTimeInterval(0.058322))
        #expect(snapshot.worstPercent == 35)
        #expect(snapshot.windows.map(\.duration) == [604_800, 604_800])
        #expect(snapshot.fetchedAt == now)
    }

    @Test func fiveHourPresentAndLimitsAbsent() throws {
        let data = json("""
        {"five_hour":{"utilization":72.5,"resets_at":"2026-11-14T15:00:00+00:00"},
         "seven_day":{"utilization":40,"resets_at":null}}
        """)
        let snapshot = try ClaudeProvider.parse(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["5h", "Week"])
        #expect(snapshot.windows[0].resetsAt == parseISO8601("2026-11-14T15:00:00Z"))
        #expect(snapshot.windows[1].resetsAt == nil)
    }

    @Test func nonWeeklyScopedLimit() throws {
        let data = json("""
        {"limits":[
          {"group":"daily","percent":10,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}},
          {"percent":20,"resets_at":null,"scope":{"model":{"display_name":"Opus"}}}]}
        """)
        let snapshot = try ClaudeProvider.parse(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["daily · Fable", "Limit · Opus"])
        #expect(snapshot.windows.map(\.duration) == [nil, nil])
    }

    @Test func malformedThrows() {
        #expect(throws: UsageError.badResponse) { try ClaudeProvider.parse(json("[1]"), now: now) }
    }
}

@Suite struct ClaudeCredentialsTests {
    private func credentials(_ json: String, status: Int32 = 0, timedOut: Bool = false) throws -> (token: String, plan: String?) {
        try ClaudeProvider.credentials(fromSecurityOutput: Data(json.utf8), status: status, timedOut: timedOut)
    }

    @Test func validItem() throws {
        let result = try credentials(#"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"max"}}"#)
        #expect(result.token == "tok")
        #expect(result.plan == "max")
    }

    @Test func itemWithoutSubscriptionLoginIsNotSignedIn() {
        #expect(throws: UsageError.notSignedIn(cli: "claude")) { try credentials(#"{"mcpOAuth":{}}"#) }
    }

    @Test func missingItemIsNotSignedIn() {
        #expect(throws: UsageError.notSignedIn(cli: "claude")) { try credentials("", status: 44) }
    }

    @Test func otherFailureIsUnreadable() {
        #expect(throws: UsageError.credentialsUnreadable(cli: "claude")) { try credentials("", status: 1) }
    }

    @Test func invalidJSONIsUnreadable() {
        #expect(throws: UsageError.credentialsUnreadable(cli: "claude")) { try credentials("not json") }
    }

    @Test func killedProcessIsTimeout() {
        #expect(throws: UsageError.keychainTimeout) { try credentials("", status: 15, timedOut: true) }
    }
}

@Suite struct CodexParsingTests {
    @Test func codexCredentialsFromAuthFile() throws {
        let credentials = try CodexProvider.credentials(fromAuthFile: json(#"{"tokens":{"access_token":"t","account_id":"a"}}"#))
        #expect(credentials.accessToken == "t")
        #expect(credentials.accountID == "a")
        #expect(throws: UsageError.notSignedIn(cli: "codex")) { try CodexProvider.credentials(fromAuthFile: json(#"{"tokens":null}"#)) }
        #expect(throws: UsageError.notSignedIn(cli: "codex")) { try CodexProvider.credentials(fromAuthFile: json("{}")) }
        #expect(throws: UsageError.credentialsUnreadable(cli: "codex")) { try CodexProvider.credentials(fromAuthFile: json("not json")) }
    }

    @Test func primaryOnly() throws {
        let data = json("""
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":18,"limit_window_seconds":604800,"reset_after_seconds":581123,"reset_at":1795253766},
          "secondary_window":null}}
        """)
        let snapshot = try CodexProvider.parse(data, now: now)
        #expect(snapshot.plan == "pro")
        #expect(snapshot.windows == [LimitWindow(label: "Week", usedPercent: 18, resetsAt: Date(timeIntervalSince1970: 1_795_253_766), duration: 604_800)])
    }

    @Test func bothWindows() throws {
        let data = json("""
        {"plan_type":"plus","rate_limit":{
          "primary_window":{"used_percent":91,"limit_window_seconds":18000,"reset_at":1795200000},
          "secondary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_at":1795253766}}}
        """)
        let snapshot = try CodexProvider.parse(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["5h", "Week"])
        #expect(snapshot.worstPercent == 91)
    }
}

@Suite struct GrokParsingTests {
    @Test func weekly() throws {
        let data = json("""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-13T12:28:31.983+00:00","end":"2026-11-20T12:28:31.983+00:00"},
          "creditUsagePercent":57.0,
          "productUsage":[{"product":"GrokBot","usagePercent":40.0},{"product":"Cursor","usagePercent":17.0}]}}
        """)
        let snapshot = try GrokProvider.parse(data, now: now)
        #expect(snapshot.plan == nil)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "Week")
        #expect(snapshot.windows[0].usedPercent == 57)
        #expect(snapshot.windows[0].resetsAt == parseISO8601("2026-11-20T12:28:31Z")!.addingTimeInterval(0.983))
        #expect(snapshot.windows[0].duration == 604_800)
    }

    @Test func bearerKeyFromAuthFile() throws {
        #expect(try GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.x.ai::a":{"other":1},"https://auth.x.ai::b":{"key":"k1"}}"#)) == "k1")
        #expect(try GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.evil.example::a":{"key":"bad"},"https://auth.x.ai::b":{"key":"k1"}}"#)) == "k1")
        #expect(try GrokProvider.bearerKey(fromAuthFile: json(#"{"https://other.example::a":{"key":"bad"}}"#)) == nil)
        #expect(try GrokProvider.bearerKey(fromAuthFile: json("{}")) == nil)
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) { try GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.x.ai::a":{}}"#)) }
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) { try GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.x.ai::a":{"key":123}}"#)) }
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) { try GrokProvider.bearerKey(fromAuthFile: json("not json")) }
        #expect(throws: UsageError.credentialsUnreadable(cli: "grok")) { try GrokProvider.bearerKey(fromAuthFile: json("[1]")) }
    }

    @Test func planFromSettings() {
        #expect(GrokProvider.parsePlan(json(#"{"subscription_tier_display":"SuperGrok Heavy","subscription_tier":null}"#)) == "SuperGrok Heavy")
        #expect(GrokProvider.parsePlan(json(#"{"subscription_tier_display":"   ","subscription_tier":"supergrok"}"#)) == "supergrok")
        #expect(GrokProvider.parsePlan(json(#"{"subscription_tier_display":null}"#)) == nil)
        #expect(GrokProvider.parsePlan(json("not json")) == nil)
    }
}

@Suite struct AntigravityCredentialsTests {
    private func credentials(_ raw: String, status: Int32 = 0, timedOut: Bool = false) throws -> String {
        try AntigravityProvider.credentials(fromSecurityOutput: Data(raw.utf8), status: status, timedOut: timedOut)
    }

    @Test func goKeyringBase64Payload() throws {
        let payload = #"{"token":{"access_token":"ya29.test"},"auth_method":"oauth"}"#
        let encoded = "go-keyring-base64:" + Data(payload.utf8).base64EncodedString() + "\n"
        #expect(try credentials(encoded) == "ya29.test")
    }

    @Test func rawJSONPayload() throws {
        #expect(try credentials(#"{"token":{"access_token":"ya29.raw"}}"#) == "ya29.raw")
    }

    @Test func missingItemIsNotSignedIn() {
        #expect(throws: UsageError.notSignedIn(cli: "agy")) { try credentials("", status: 44) }
    }

    @Test func missingTokenIsNotSignedIn() {
        #expect(throws: UsageError.notSignedIn(cli: "agy")) { try credentials(#"{"token":null}"#) }
        #expect(throws: UsageError.notSignedIn(cli: "agy")) { try credentials(#"{"token":{"access_token":""}}"#) }
    }

    @Test func invalidBase64OrJSONIsUnreadable() {
        #expect(throws: UsageError.credentialsUnreadable(cli: "agy")) { try credentials("go-keyring-base64:%%%") }
        #expect(throws: UsageError.credentialsUnreadable(cli: "agy")) { try credentials("not json") }
        #expect(throws: UsageError.credentialsUnreadable(cli: "agy")) { try credentials("", status: 1) }
    }

    @Test func killedProcessIsTimeout() {
        #expect(throws: UsageError.keychainTimeout) { try credentials("", status: 15, timedOut: true) }
    }
}

@Suite struct AntigravityParsingTests {
    @Test func loadCodeAssistTiers() throws {
        let paid = try AntigravityProvider.parseLoadCodeAssist(json("""
        {"cloudaicompanionProject":"proj-1","currentTier":{"id":"free-tier","name":"Antigravity"},
         "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}
        """))
        #expect(paid.project == "proj-1")
        #expect(paid.plan == "pro")

        let ultra = try AntigravityProvider.parseLoadCodeAssist(json(#"{"paidTier":{"id":"g1-ultra-tier"}}"#))
        #expect(ultra.plan == "ultra")

        let free = try AntigravityProvider.parseLoadCodeAssist(json(#"{"currentTier":{"id":"free-tier"}}"#))
        #expect(free.project == nil)
        #expect(free.plan == "free")
    }

    @Test func showsOnlyMainGeminiWeeklyWhenFiveHourIsCalm() throws {
        let now = try #require(parseISO8601("2026-11-23T15:33:19Z"))
        let data = json("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-11-30T11:30:19Z","remainingFraction":0.8989852},
            {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-11-23T16:30:19Z","remainingFraction":0.64644825}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","window":"weekly","resetTime":"2026-11-30T15:32:25Z","remainingFraction":0.4},
            {"bucketId":"3p-5h","window":"5h","resetTime":"2026-11-23T20:32:25Z","remainingFraction":0.1}
          ]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","resetTime":"2026-11-30T15:32:25Z","remainingFraction":0.2}
          ]}
        ]}
        """)
        let snapshot = try AntigravityProvider.parseQuotaSummary(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["Week"])
        #expect(abs(snapshot.windows[0].usedPercent - 10.10148) < 0.001)
        #expect(snapshot.windows[0].duration == 604_800)
        #expect(snapshot.windows[0].resetsAt == parseISO8601("2026-11-30T11:30:19Z"))
        #expect(snapshot.fetchedAt == now)
    }

    @Test func showsFiveHourWhenOverFiftyPercentAndAtLeastTwentyOverPace() throws {
        // 4h remaining out of 5h -> 1h elapsed -> 20% pace.
        let now = try #require(parseISO8601("2026-11-23T12:00:00Z"))
        let fourHoursLeft = "2026-11-23T16:00:00Z"
        let twoHoursLeft = "2026-11-23T14:00:00Z" // 60% pace

        func payload(fiveHourRemaining: Double, fiveHourReset: String) -> Data {
            json("""
            {"groups":[
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-11-30T12:00:00Z","remainingFraction":0.8},
                {"bucketId":"gemini-5h","window":"5h","resetTime":"\(fiveHourReset)","remainingFraction":\(fiveHourRemaining)}
              ]}
            ]}
            """)
        }

        // 55% used at 20% pace (+35% over pace, > 50%) -> shown.
        let triggered = try AntigravityProvider.parseQuotaSummary(payload(fiveHourRemaining: 0.45, fiveHourReset: fourHoursLeft), now: now)
        #expect(triggered.windows.map(\.label) == ["Week", "5h"])
        #expect(triggered.windows.map(\.duration) == [604_800, 18_000])
        #expect(abs(triggered.windows[1].usedPercent - 55) < 0.001)

        // 45% used at 20% pace (+25% over pace, <= 50%) -> hidden.
        let underFifty = try AntigravityProvider.parseQuotaSummary(payload(fiveHourRemaining: 0.55, fiveHourReset: fourHoursLeft), now: now)
        #expect(underFifty.windows.map(\.label) == ["Week"])

        // 70% used at 60% pace (> 50%, only +10% over pace) -> hidden.
        let slightOverPace = try AntigravityProvider.parseQuotaSummary(payload(fiveHourRemaining: 0.30, fiveHourReset: twoHoursLeft), now: now)
        #expect(slightOverPace.windows.map(\.label) == ["Week"])
    }

    @Test func showsFiveHourWhenAtOrAboveEightyPercentOrExhausted() throws {
        // 30m remaining out of 5h -> 90% pace.
        let now = try #require(parseISO8601("2026-11-23T12:00:00Z"))
        let data = json("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-11-30T12:00:00Z","remainingFraction":0.7},
            {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-11-23T12:30:00Z","remainingFraction":0.2}
          ]}
        ]}
        """)
        let high = try AntigravityProvider.parseQuotaSummary(data, now: now)
        #expect(high.windows.map(\.label) == ["Week", "5h"])
        #expect(abs(high.windows[1].usedPercent - 80) < 0.001)

        let exhausted = json("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2026-11-30T12:00:00Z"},
            {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-11-23T12:30:00Z"}
          ]}
        ]}
        """)
        let snapshot = try AntigravityProvider.parseQuotaSummary(exhausted, now: now)
        #expect(snapshot.windows.map(\.label) == ["Week", "5h"])
        #expect(snapshot.windows.map(\.usedPercent) == [100, 100])
    }

    @Test func matchesByDisplayNameAndHandlesMissingWeekly() throws {
        let now = try #require(parseISO8601("2026-11-23T12:00:00Z"))
        let byDisplayName = json("""
        {"groups":[
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","resetTime":"2026-11-30T12:00:00Z","remainingFraction":0.1}
          ]},
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"custom-weekly","window":"weekly","resetTime":"2026-11-30T12:00:00Z","remainingFraction":0.75}
          ]}
        ]}
        """)
        let weeklyOnly = try AntigravityProvider.parseQuotaSummary(byDisplayName, now: now)
        #expect(weeklyOnly.windows.map(\.label) == ["Week"])
        #expect(abs(weeklyOnly.windows[0].usedPercent - 25) < 0.001)

        let fiveHourOnlyData = json("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-11-23T16:00:00Z","remainingFraction":0.9}
          ]}
        ]}
        """)
        let fiveHourOnly = try AntigravityProvider.parseQuotaSummary(fiveHourOnlyData, now: now)
        #expect(fiveHourOnly.windows.map(\.label) == ["5h"])
        #expect(abs(fiveHourOnly.windows[0].usedPercent - 10) < 0.001)
    }

    @Test func malformedThrows() {
        #expect(throws: UsageError.badResponse) { try AntigravityProvider.parseQuotaSummary(json("[1]"), now: now) }
    }
}
