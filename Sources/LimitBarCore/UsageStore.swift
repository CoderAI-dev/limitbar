import Foundation
import Observation

@MainActor @Observable
public final class UsageStore {
    public private(set) var states: [ProviderID: ProviderState] = [:]
    public private(set) var lastUpdated: Date?
    public private(set) var isRefreshing = false

    private let providers: [any UsageProvider]
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    public init(providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), GrokProvider()]) {
        self.providers = providers
        for provider in providers { states[provider.id] = .loading }
    }

    /// Provider IDs in display order.
    public var order: [ProviderID] { providers.map(\.id) }

    /// Provider IDs to show: those not signed in are hidden, unless none is signed in at all,
    /// in which case all are shown so each can display its sign-in hint.
    public var visibleOrder: [ProviderID] {
        let visible = order.filter { id in
            if case .unavailable = states[id] { false } else { true }
        }
        return visible.isEmpty ? order : visible
    }

    /// Refreshes now and then every 5 minutes for the lifetime of the store.
    public func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Refreshes only if the data is older than 60 seconds.
    public func refreshIfStale(now: Date = Date()) async {
        if let lastUpdated, now.timeIntervalSince(lastUpdated) < 60 { return }
        await refresh()
    }

    /// Fetches all providers concurrently; each one updates independently.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetch())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let snapshot):
                    states[id] = .loaded(snapshot)
                case .failure(let error as UsageError):
                    if case .notSignedIn = error {
                        states[id] = .unavailable(message: error.errorDescription ?? "Not signed in")
                    } else {
                        states[id] = .failed(message: error.errorDescription ?? "Request failed", lastSnapshot: states[id]?.snapshot)
                    }
                case .failure:
                    states[id] = .failed(message: "Request failed", lastSnapshot: states[id]?.snapshot)
                }
            }
        }
        lastUpdated = Date()
    }
}
