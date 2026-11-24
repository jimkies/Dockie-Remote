import SwiftUI

@main
struct DockieRemoteApp: App {
    @State private var store = RemoteStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: store.enterForeground()
            case .background: store.enterBackground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        Group {
            if store.pc == nil {
                PairView()
            } else {
                AccountsView()
            }
        }
        .overlay(alignment: .top) {
            if let banner = store.banner {
                BannerView(banner: banner) { store.dismissBanner() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
        }
        .animation(Theme.easeOut, value: store.banner)
        // Theme switches stay instant: nothing here animates on colour scheme.
    }
}
