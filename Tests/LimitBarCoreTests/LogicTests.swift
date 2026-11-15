import Foundation
import Testing
@testable import LimitBarCore

@Suite struct LogicTests {
    @Test func dateParsingVariants() throws {
        let base = try #require(parseISO8601("2026-11-21T03:00:00+00:00"))
        #expect(base == Date(timeIntervalSince1970: 1_795_230_000))
        let six = try #require(parseISO8601("2026-11-21T03:00:00.058322+00:00"))
        #expect(abs(six.timeIntervalSince(base) - 0.058322) < 1e-6)
        let three = try #require(parseISO8601("2026-11-21T03:00:00.983Z"))
        #expect(abs(three.timeIntervalSince(base) - 0.983) < 1e-6)
        #expect(parseISO8601("2026-11-21T05:00:00+02:00") == base)
        #expect(parseISO8601("garbage") == nil)
    }

    @Test(arguments: [(18_000, "5h"), (604_800, "Week"), (10_800, "3h"), (172_800, "2d"), (900, "15m")])
    func windowLabels(seconds: Int, label: String) {
        #expect(windowLabel(seconds: seconds) == label)
    }

    @Test func percentClamping() {
        #expect(LimitWindow(label: "a", usedPercent: 140, resetsAt: nil).usedPercent == 100)
        #expect(LimitWindow(label: "a", usedPercent: -3, resetsAt: nil).usedPercent == 0)
    }

    @Test func worstPercent() {
        let now = Date()
        #expect(ProviderSnapshot(windows: [], plan: nil, fetchedAt: now).worstPercent == nil)
        let windows = [LimitWindow(label: "a", usedPercent: 12, resetsAt: nil), LimitWindow(label: "b", usedPercent: 64, resetsAt: nil)]
        #expect(ProviderSnapshot(windows: windows, plan: nil, fetchedAt: now).worstPercent == 64)
    }

    @Test func resetFormatting() {
        let now = Date(timeIntervalSince1970: 0)
        func text(_ seconds: Double) -> String { resetDescription(until: now.addingTimeInterval(seconds), now: now) }
        #expect(text(30) == "resets soon")
        #expect(text(-100) == "resets soon")
        #expect(text(7 * 60) == "resets in 7m")
        #expect(text(3 * 3600 + 12 * 60) == "resets in 3h 12m")
        #expect(text(2 * 3600) == "resets in 2h")
        #expect(text(86_400 + 4 * 3600 + 59) == "resets in 1d 4h")
        #expect(text(2 * 86_400) == "resets in 2d")
        // Absurd timestamps (e.g. reset_at: 1e20) are clamped instead of trapping.
        #expect(text(1e20) == "resets in 3650d")
    }

    @Test func failedStateKeepsSnapshot() {
        let snapshot = ProviderSnapshot(windows: [], plan: "pro", fetchedAt: Date())
        #expect(ProviderState.failed(message: "x", lastSnapshot: snapshot).snapshot == snapshot)
        #expect(ProviderState.loading.snapshot == nil)
    }

    @Test func pacePercent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func pace(daysElapsed: Double) -> Double? {
            let resetsAt = now.addingTimeInterval((7 - daysElapsed) * 86_400)
            return LimitWindow(label: "Week", usedPercent: 0, resetsAt: resetsAt, duration: 604_800).pacePercent(now: now)
        }
        // The weekly budget is spread over 6 days, so 3 days in is half and day 6 onward is full.
        #expect(abs(pace(daysElapsed: 3)! - 50) < 0.001)
        #expect(pace(daysElapsed: 0) == 0)
        #expect(pace(daysElapsed: 6) == 100)
        #expect(pace(daysElapsed: 6.5) == 100)
        #expect(pace(daysElapsed: -1) == 0)
        // Short windows use their full length: 2.5h into a 5h window is half.
        let fiveHour = LimitWindow(label: "5h", usedPercent: 0, resetsAt: now.addingTimeInterval(9_000), duration: 18_000)
        #expect(fiveHour.pacePercent(now: now) == 50)
        #expect(LimitWindow(label: "a", usedPercent: 0, resetsAt: now).pacePercent(now: now) == nil)
        #expect(LimitWindow(label: "a", usedPercent: 0, resetsAt: nil, duration: 60).pacePercent(now: now) == nil)
    }

    @Test func paceFormatting() {
        #expect(paceDescription(usedPercent: 40, pacePercent: 28.2) == "12% over pace")
        #expect(paceDescription(usedPercent: 20, pacePercent: 28.4) == "8% spare")
        #expect(paceDescription(usedPercent: 30, pacePercent: 30.3) == "on pace")
    }
}
