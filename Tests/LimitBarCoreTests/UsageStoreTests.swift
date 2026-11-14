import Foundation
import Testing
@testable import LimitBarCore

/// A provider whose next result is set by the test; counts fetches.
private final class FakeProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var result: Result<ProviderSnapshot, Error>
    private var count = 0
    private let delay: Duration?

    init(_ id: ProviderID, _ result: Result<ProviderSnapshot, Error>, delay: Duration? = nil) {
        self.id = id
        self.result = result
        self.delay = delay
    }

    var fetchCount: Int { lock.withLock { count } }
    func setResult(_ result: Result<ProviderSnapshot, Error>) { lock.withLock { self.result = result } }

    func fetch() async throws -> ProviderSnapshot {
        if let delay { try await Task.sleep(for: delay) }
        return try lock.withLock {
            count += 1
            return try result.get()
        }
    }
}

private struct OtherError: Error {}

private let snapshot = ProviderSnapshot(
    windows: [LimitWindow(label: "5h", usedPercent: 42, resetsAt: nil)],
    plan: nil,
    fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
)

@MainActor @Suite struct UsageStoreTests {
    @Test func failureAfterSuccessKeepsLastSnapshot() async {
        let provider = FakeProvider(.claude, .success(snapshot))
        let store = UsageStore(providers: [provider])
        await store.refresh()
        #expect(store.states[.claude] == .loaded(snapshot))

        provider.setResult(.failure(UsageError.http(status: 500)))
        await store.refresh()
        #expect(store.states[.claude] == .failed(message: "Request failed (HTTP 500)", lastSnapshot: snapshot))
        #expect(store.states[.claude]?.isStale == true)
    }

    @Test func errorMessages() async {
        let store = UsageStore(providers: [
            FakeProvider(.claude, .failure(UsageError.keychainTimeout)),
            FakeProvider(.codex, .failure(OtherError())),
        ])
        await store.refresh()
        #expect(store.states[.claude] == .failed(message: UsageError.keychainTimeout.errorDescription!, lastSnapshot: nil))
        #expect(store.states[.codex] == .failed(message: "Request failed", lastSnapshot: nil))
    }

    @Test func failureIsIsolatedPerProvider() async {
        let store = UsageStore(providers: [
            FakeProvider(.claude, .failure(OtherError())),
            FakeProvider(.grok, .success(snapshot)),
        ])
        await store.refresh()
        #expect(store.states[.grok] == .loaded(snapshot))
        #expect(store.states[.claude]?.isStale == true)
    }

    @Test func refreshIfStaleSkipsRecentRefresh() async {
        let provider = FakeProvider(.codex, .success(snapshot))
        let store = UsageStore(providers: [provider])
        await store.refreshIfStale()
        await store.refreshIfStale()
        #expect(provider.fetchCount == 1)
        await store.refresh()
        #expect(provider.fetchCount == 2)
        await store.refreshIfStale(now: Date().addingTimeInterval(61))
        #expect(provider.fetchCount == 3)
    }

    @Test func overlappingRefreshIsDropped() async {
        let provider = FakeProvider(.grok, .success(snapshot), delay: .milliseconds(100))
        let store = UsageStore(providers: [provider])
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        #expect(provider.fetchCount == 1)
        #expect(store.isRefreshing == false)
    }
}
