import Foundation

/// Parses ISO 8601 timestamps with any number of fractional digits (or none)
/// and a `Z` or `±hh:mm` offset, e.g. `2026-11-21T03:00:00.058322+00:00`.
public func parseISO8601(_ string: String) -> Date? {
    var base = string
    var fraction = 0.0
    if let dot = string.firstIndex(of: ".") {
        let digitsEnd = string[dot...].dropFirst().firstIndex { !$0.isNumber } ?? string.endIndex
        fraction = Double("0" + string[dot..<digitsEnd]) ?? 0
        base = String(string[..<dot] + string[digitsEnd...])
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: base).map { $0.addingTimeInterval(fraction) }
}

/// Compact label for a window length: 18000 → "5h", 604800 → "Week", 172800 → "2d".
public func windowLabel(seconds: Int) -> String {
    switch seconds {
    case 604_800: return "Week"
    case let s where s > 0 && s % 86_400 == 0: return "\(s / 86_400)d"
    case let s where s > 0 && s % 3_600 == 0: return "\(s / 3_600)h"
    default: return "\(max(seconds, 0) / 60)m"
    }
}

/// "resets in 1d 4h", "resets in 3h 12m", "resets in 7m", or "resets soon".
public func resetDescription(until date: Date, now: Date) -> String {
    // Clamp before converting: a nonsensical far-future timestamp must not trap in Int(_:).
    let seconds = Int(min(max(date.timeIntervalSince(now), 0), 3_650 * 86_400))
    guard seconds >= 60 else { return "resets soon" }
    let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
    let text: String
    if days > 0 {
        text = hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    } else if hours > 0 {
        text = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    } else {
        text = "\(minutes)m"
    }
    return "resets in \(text)"
}

/// How usage compares to an even pace: "12% over pace", "8% spare", or "on pace".
public func paceDescription(usedPercent: Double, pacePercent: Double) -> String {
    let delta = Int((usedPercent - pacePercent).rounded())
    if delta > 0 { return "\(delta)% over pace" }
    if delta < 0 { return "\(-delta)% spare" }
    return "on pace"
}

/// Formats a subscription plan name for display: capitalizes all-lowercase names ("pro" → "Pro"),
/// while preserving intentional mixed casing ("SuperGrok Heavy", "Google AI Pro").
public func formatPlan(_ plan: String) -> String {
    plan == plan.lowercased() ? plan.capitalized : plan
}
