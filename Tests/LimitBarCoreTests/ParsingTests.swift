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

@Suite struct CodexParsingTests {
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

    @Test func bearerKeyFromAuthFile() {
        #expect(GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.x.ai::a":{"other":1},"https://auth.x.ai::b":{"key":"k1"}}"#)) == "k1")
        #expect(GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.evil.example::a":{"key":"bad"},"https://auth.x.ai::b":{"key":"k1"}}"#)) == "k1")
        #expect(GrokProvider.bearerKey(fromAuthFile: json(#"{"https://other.example::a":{"key":"bad"}}"#)) == nil)
        #expect(GrokProvider.bearerKey(fromAuthFile: json(#"{"https://auth.x.ai::a":{}}"#)) == nil)
    }
}
