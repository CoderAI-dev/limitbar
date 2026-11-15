import LimitBarCore
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    let store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.visibleOrder.enumerated()), id: \.element) { index, id in
                if index > 0 { Divider().padding(.vertical, 10) }
                ProviderSection(
                    id: id,
                    state: store.states[id] ?? .loading,
                    isRefreshing: store.isRefreshing,
                    onRetry: { Task { await store.refresh() } }
                )
            }
            Divider().padding(.top, 12).padding(.bottom, 8)
            footer
        }
        .padding(14)
        .frame(width: 300)
        .task { await store.refreshIfStale() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updatedText(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("Refresh")
                }
            }
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private func updatedText(now: Date) -> String {
        guard let lastUpdated = store.lastUpdated else { return store.isRefreshing ? "Updating…" : "Not updated yet" }
        let minutes = Int(now.timeIntervalSince(lastUpdated) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes) min ago"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Fall through: the toggle reflects the real status below.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
