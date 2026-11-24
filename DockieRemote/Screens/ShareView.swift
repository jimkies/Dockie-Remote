import SwiftUI

/// Full-screen view of one shared window. Leaving it sends stopShare once.
struct ShareView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ShareSession
    @State private var appeared = false

    private var account: Account? { store.accounts.first { $0.id == session.id } }
    private var phase: ShareSession.Phase { store.share?.phase ?? session.phase }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = store.images[session.id] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea(edges: .horizontal)
                    .accessibilityLabel("Window of \(account?.displayName ?? "account")")
            }
            if phase == .starting {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Starting share…").font(.headline).foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            VStack {
                topBar
                Spacer()
                Button { store.stopShare() } label: {
                    Label("Stop sharing", systemImage: "stop.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: Color(red: 0.82, green: 0.22, blue: 0.24)))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // Enters from 0.97 with a fade, never from zero.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(Theme.easeOut) { appeared = true } }
        .onDisappear { store.stopShare() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.displayName ?? "Sharing").font(.headline)
                if let username = account?.username {
                    Text("@\(username)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let end = account?.shareEndsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(countdownText(until: store.localDate(pcMillis: end), now: context.date), systemImage: "timer")
                        .monospacedDigit()
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("Stops automatically in \(countdownText(until: store.localDate(pcMillis: end), now: context.date))")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}
