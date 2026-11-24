import SwiftUI

struct AccountsView: View {
    @Environment(RemoteStore.self) private var store
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                if store.accounts.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.accounts) { account in
                            AccountCard(account: account, image: store.images[account.id])
                        }
                    }
                    .padding(16)
                }
            }
            .refreshable { await store.refresh() }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle(store.pc?.name ?? "Dockie")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionPill() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .fullScreenCover(item: $store.shareBinding) { session in
                ShareView(session: session)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isConnected {
                Image(systemName: "rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                Text("No accounts yet").font(.headline)
                Text("Add accounts in Dockie on your PC.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Connecting to \(store.pc?.name ?? "your PC")…").font(.headline)
                Text("Pull down to retry. Away from home? Add your PC's Tailscale IP in Settings.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, 32)
    }
}

private struct ConnectionPill: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isConnected ? Theme.live : Theme.offline).frame(width: 8, height: 8)
            Text(store.statusText).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
        .accessibilityElement(children: .combine)
    }
}

struct AccountCard: View {
    @Environment(RemoteStore.self) private var store
    let account: Account
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            frame
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("@\(account.username)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            HStack(spacing: 8) {
                StateBadge(account: account)
                Spacer(minLength: 0)
                if account.canShare {
                    Button { store.startShare(account) } label: {
                        Label("Share", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).frame(minHeight: 30)
                            .background(Theme.sharing, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!store.isConnected || store.share != nil)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .padding(Theme.cardPadding)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }

    private var frame: some View {
        ZStack {
            Color.black
            if let image {
                // No animation here: frames replace each other many times a second.
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .opacity(account.state == .offline ? 0.45 : 1)
            } else {
                Image(systemName: account.state == .offline ? "moon.zzz" : "photo")
                    .font(.title2).foregroundStyle(.white.opacity(0.4))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
    }
}

struct StateBadge: View {
    @Environment(RemoteStore.self) private var store
    let account: Account

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(text(now: context.date)).monospacedDigit().lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch account.state {
        case .live: return Theme.live
        case .minimized: return Theme.minimized
        case .sharing: return Theme.sharing
        case .offline: return Theme.offline
        }
    }

    private func text(now: Date) -> String {
        switch account.state {
        case .live: return "Live"
        case .minimized:
            guard let at = account.snapshotAt else { return "Minimized" }
            return "Minimized · \(ageText(since: store.localDate(pcMillis: at), now: now))"
        case .sharing:
            guard let end = account.shareEndsAt else { return "Sharing" }
            return "Sharing · \(countdownText(until: store.localDate(pcMillis: end), now: now))"
        case .offline: return "Offline"
        }
    }
}
