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

    @Test func mergesSharedQuotaGroupsAndIgnoresInternalAndTabModels() throws {
        let now = try #require(parseISO8601("2026-11-23T11:37:00Z"))
        let data = json("""
        {"models":{
          "gemini-2.5-pro":{"recommended":true,"modelProvider":"MODEL_PROVIDER_GOOGLE",
            "quotaInfo":{"remainingFraction":0.92,"resetTime":"2026-11-23T16:30:00Z"}},
          "gemini-3-flash":{"recommended":true,"modelProvider":"MODEL_PROVIDER_GOOGLE",
            "quotaInfo":{"remainingFraction":0.92,"resetTime":"2026-11-23T16:30:00Z"}},
          "claude-opus-5-5-high":{"recommended":true,"modelProvider":"MODEL_PROVIDER_ANTHROPIC",
            "quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-23T16:37:00Z"}},
          "gpt-oss-120b-medium":{"recommended":true,"modelProvider":"MODEL_PROVIDER_OPENAI",
            "quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-23T16:37:00Z"}},
          "chat_20706":{"isInternal":true,"recommended":true,"modelProvider":"MODEL_PROVIDER_GOOGLE",
            "quotaInfo":{"remainingFraction":0.1,"resetTime":"2026-11-23T16:30:00Z"}},
          "tab_flash_lite_preview":{"modelProvider":"MODEL_PROVIDER_GOOGLE",
            "quotaInfo":{"remainingFraction":1}}
        }}
        """)
        let snapshot = try AntigravityProvider.parseModels(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["Gemini", "Claude · GPT"])
        #expect(abs(snapshot.windows[0].usedPercent - 8) < 0.001)
        #expect(snapshot.windows[1].usedPercent == 0)
        #expect(snapshot.windows[0].resetsAt == parseISO8601("2026-11-23T16:30:00Z"))
        #expect(snapshot.windows.map(\.duration) == [18_000, 18_000])
        #expect(snapshot.fetchedAt == now)
    }

    @Test func splitsDivergingGroupsAndHandlesExhaustedOmittedFraction() throws {
        let now = try #require(parseISO8601("2026-11-23T11:37:00Z"))
        let data = json("""
        {"models":{
          "gemini-2.5-pro":{"recommended":true,"modelProvider":"MODEL_PROVIDER_GOOGLE",
            "quotaInfo":{"resetTime":"2026-11-23T16:30:00Z"}},
          "gemini-3-flash":{"recommended":true,"modelProvider":"MODEL_PROVIDER_GOOGLE",
            "quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-11-23T16:30:00Z"}},
          "claude-sonnet-5-5-high":{"recommended":true,"modelProvider":"MODEL_PROVIDER_ANTHROPIC",
            "quotaInfo":{"remainingFraction":0.25,"resetTime":"2026-11-29T11:37:00Z"}},
          "gpt-oss-120b-medium":{"recommended":true,"modelProvider":"MODEL_PROVIDER_OPENAI",
            "quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-11-23T16:30:00Z"}}
        }}
        """)
        let snapshot = try AntigravityProvider.parseModels(data, now: now)
        #expect(snapshot.windows.map(\.label) == ["Gemini Pro", "Gemini Flash", "Claude", "GPT"])
        for (actual, expected) in zip(snapshot.windows.map(\.usedPercent), [100.0, 40.0, 75.0, 20.0]) {
            #expect(abs(actual - expected) < 0.001)
        }
        #expect(snapshot.windows.map(\.duration) == [18_000, 18_000, 604_800, 18_000])
    }

    @Test func malformedThrows() {
        #expect(throws: UsageError.badResponse) { try AntigravityProvider.parseModels(json("[1]"), now: now) }
    }
}
