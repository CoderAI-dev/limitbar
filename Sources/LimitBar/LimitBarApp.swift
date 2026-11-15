import LimitBarCore
import SwiftUI

@main
struct LimitBarApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            let items = store.visibleOrder.map { id in
                let state = store.states[id]
                return MenuBarIcon.Item(id: id, percent: state?.snapshot?.worstPercent, stale: state?.isStale ?? false)
            }
            Image(nsImage: MenuBarIcon.image(for: items))
                .accessibilityLabel(MenuBarIcon.accessibilityLabel(for: items))
                .task { store.startAutoRefresh() }
        }
        .menuBarExtraStyle(.window)
    }
}
