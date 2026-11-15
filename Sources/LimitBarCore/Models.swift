import Foundation

public enum ProviderID: String, CaseIterable, Sendable {
    case claude, codex, grok

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }

    /// Single letter shown in the menu bar.
    public var letter: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .grok: "G"
        }
    }

    public var cliName: String { rawValue }
}

public struct LimitWindow: Equatable, Sendable {
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Length of the limit window in seconds, when known.
    public let duration: TimeInterval?

    /// Windows of a week or longer budget usage over 6/7 of their length (6 of 7 days), leaving
    /// the rest as a buffer; shorter windows (e.g. 5h) use their full length.
    static func paceBudgetShare(duration: TimeInterval) -> Double {
        duration >= 604_800 ? 6.0 / 7.0 : 1
    }

    public init(label: String, usedPercent: Double, resetsAt: Date?, duration: TimeInterval? = nil) {
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.duration = duration
    }

    /// The usage percent an even pace would have reached by `now`: 100% once the budgeted
    /// share of the window has elapsed. Nil when the window's timing is unknown.
    public func pacePercent(now: Date) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let elapsed = duration - resetsAt.timeIntervalSince(now)
        return min(max(elapsed / (duration * Self.paceBudgetShare(duration: duration)), 0), 1) * 100
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public let windows: [LimitWindow]
    public let plan: String?
    public let fetchedAt: Date

    public init(windows: [LimitWindow], plan: String?, fetchedAt: Date) {
        self.windows = windows
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    public var worstPercent: Double? { windows.map(\.usedPercent).max() }
}

public enum ProviderState: Equatable, Sendable {
    case loading
    case loaded(ProviderSnapshot)
    case failed(message: String, lastSnapshot: ProviderSnapshot?)
    /// The provider's CLI is not signed in; the message tells how to sign in.
    case unavailable(message: String)

    /// The snapshot to display, fresh or stale.
    public var snapshot: ProviderSnapshot? {
        switch self {
        case .loading, .unavailable: nil
        case .loaded(let snapshot): snapshot
        case .failed(_, let snapshot): snapshot
        }
    }

    /// True when the displayed snapshot (if any) is from before the latest failed refresh.
    public var isStale: Bool {
        if case .failed = self { true } else { false }
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}

/// Errors with short, token-free messages suitable for the UI.
public enum UsageError: Error, Equatable, LocalizedError {
    case notSignedIn(cli: String)
    case sessionExpired(cli: String)
    case http(status: Int)
    case network(String)
    case badResponse
    case keychainTimeout
    case credentialsUnreadable(cli: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let cli): "Not signed in — run `\(cli)`"
        case .sessionExpired(let cli): "Session expired — run `\(cli)` once to refresh"
        case .http(let status): "Request failed (HTTP \(status))"
        case .network(let message): message
        case .badResponse: "Unexpected response format"
        case .keychainTimeout: "Keychain access timed out — allow access when macOS asks"
        case .credentialsUnreadable(let cli): "Couldn't read the `\(cli)` login"
        }
    }
}
