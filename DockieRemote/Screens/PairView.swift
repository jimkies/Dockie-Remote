import AVFoundation
import SwiftUI

struct PairView: View {
    @Environment(RemoteStore.self) private var store
    @State private var browser = BonjourBrowser()
    @State private var showScanner = false
    @State private var selected: DiscoveredPC?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let message = store.pairMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.minimized)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(radius: 16)
                    }
                    nearby
                }
                .padding(16)
                .padding(.bottom, 96)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("Pair with Dockie")
            .safeAreaInset(edge: .bottom) {
                // The primary action sits in the thumb zone.
                Button { showScanner = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .sheet(isPresented: $showScanner) {
                ScanSheet { pc in
                    showScanner = false
                    store.pair(with: pc)
                }
            }
            .sheet(item: $selected) { pc in
                TokenSheet(pc: pc) { saved in
                    selected = nil
                    store.pair(with: saved)
                }
                .presentationDetents([.medium])
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var header: some View {
        Text("Open Dockie on your PC, go to Remote, and scan the code it shows. Or pick your PC below and paste its token.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var nearby: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PCs on this network").font(.headline)
                Spacer()
                if browser.pcs.isEmpty && !browser.localNetworkDenied { ProgressView() }
            }
            if browser.localNetworkDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dockie Remote needs Local Network access to find your PC.")
                        .font(.subheadline)
                    Button("Open Settings") { openSettings() }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(radius: 16)
            } else if browser.pcs.isEmpty {
                Text("Looking for Dockie… Make sure your phone and PC are on the same Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(browser.pcs) { pc in
                        Button { selected = pc } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(pc.name).font(.body.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .foregroundStyle(.primary)
                        if pc != browser.pcs.last { Divider().overlay(Theme.border).padding(.leading, 14) }
                    }
                }
                .cardSurface(radius: 16)
            }
        }
    }
}

func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// Camera sheet with permission handling and an error shake on bad codes.
private struct ScanSheet: View {
    let onPaired: (SavedPC) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var error: String?
    @State private var shakes = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                switch status {
                case .authorized:
                    QRScannerView { code in handle(code) }.ignoresSafeArea()
                case .notDetermined:
                    Color.black.ignoresSafeArea()
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            status = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                default:
                    VStack(spacing: 12) {
                        Text("Camera access is off for Dockie Remote.").font(.headline)
                        Text("Turn it on in Settings, or close this and pick your PC from the list.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Open Settings") { openSettings() }.font(.subheadline.weight(.semibold))
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if status == .authorized {
                    Text(error ?? "Point the camera at the code in Dockie")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(error == nil ? Color.black.opacity(0.6) : Color.red.opacity(0.85), in: Capsule())
                        .shake(shakes)
                        .padding(.bottom, 32)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private func handle(_ code: String) {
        do {
            let payload = try PairingPayload.parse(code)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onPaired(payload.savedPC)
        } catch let e as PairingPayload.ParseError {
            fail(e.message)
        } catch {
            fail(PairingPayload.ParseError.notDockieCode.message)
        }
    }

    private func fail(_ message: String) {
        error = message
        shakes += 1
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

/// Resolves a Bonjour PC and asks for its token.
private struct TokenSheet: View {
    let pc: DiscoveredPC
    let onPaired: (SavedPC) -> Void
    @State private var token = ""
    @State private var resolving = false
    @State private var error: String?
    @State private var shakes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pc.name).font(.title2.weight(.semibold))
            Text("In Dockie on this PC, copy the pairing token and paste it here.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                SecureField("Pairing token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)
                Button("Paste") {
                    if let s = UIPasteboard.general.string { token = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .cardSurface(radius: 14, fill: Theme.raised)
            .shake(shakes)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            Button(action: connect) {
                if resolving { ProgressView().tint(.white) } else { Text("Connect") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolving)
        }
        .padding(20)
    }

    private func connect() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !resolving else { return }
        resolving = true
        error = nil
        Task {
            let address = await BonjourBrowser.resolve(pc)
            resolving = false
            guard let address, SavedPC.isValidHost(address.host) else {
                error = "Couldn't reach \(pc.name). Check that Dockie is running and try again."
                shakes += 1
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            onPaired(SavedPC(host: address.host, port: address.port, token: trimmed, name: pc.name, awayHost: nil))
        }
    }
}
