import LimitBarCore
import SwiftUI

struct ProviderSection: View {
    let id: ProviderID
    let state: ProviderState
    let isRefreshing: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(id.displayName).font(.headline)
                if let plan = state.snapshot?.plan {
                    Text(formatPlan(plan))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .loading = state { ProgressView().controlSize(.mini) }
            }

            if let snapshot = state.snapshot {
                if snapshot.windows.isEmpty {
                    Text("No limits reported").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { WindowRow(window: $0.element) }
                    .opacity(state.isStale ? 0.45 : 1)
            }
            if let message = errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if case .failed = state { retryButton }
                }
            }
        }
    }

    /// Retrying right away saves waiting for the next automatic refresh, e.g. after re-running the CLI.
    @ViewBuilder private var retryButton: some View {
        if isRefreshing {
            ProgressView().controlSize(.mini)
        } else {
            Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .font(.caption)
                .focusable(false)
                .help("Retry")
        }
    }

    private var errorMessage: String? {
        switch state {
        case .failed(let message, _), .unavailable(let message): message
        case .loading, .loaded: nil
        }
    }
}

private struct WindowRow: View {
    let window: LimitWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let pace = window.pacePercent(now: context.date)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(window.label)
                        .font(.callout)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)
                    UsageBar(usedPercent: window.usedPercent, pacePercent: pace, color: color)
                    Text("\(Int(window.usedPercent.rounded()))%")
                        .font(.callout.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
                if let resetsAt = window.resetsAt {
                    Text(caption(resetsAt: resetsAt, pace: pace, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func caption(resetsAt: Date, pace: Double?, now: Date) -> String {
        let reset = resetDescription(until: resetsAt, now: now)
        guard let pace else { return reset }
        return "\(reset) · \(paceDescription(usedPercent: window.usedPercent, pacePercent: pace))"
    }

    private var color: Color {
        switch window.usedPercent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }
}

/// A slim usage bar with a tick marking where an even pace would be right now:
/// fill past the tick (drawn red) means usage is ahead of pace, short of it means there is spare.
private struct UsageBar: View {
    let usedPercent: Double
    let pacePercent: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usedWidth = width * usedPercent / 100
            let overPaceWidth = pacePercent.map { max(usedWidth - width * $0 / 100, 0) } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                // The part of the fill beyond the pace tick is drawn red.
                Rectangle().fill(color)
                    .overlay(alignment: .trailing) { Rectangle().fill(.red).frame(width: overPaceWidth) }
                    .frame(width: usedWidth)
                    .clipShape(Capsule())
                if let pacePercent {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.primary)
                        .frame(width: 2, height: 12)
                        .offset(x: min(max(width * pacePercent / 100 - 1, 0), width - 2))
                }
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }
}
