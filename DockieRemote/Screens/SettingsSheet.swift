import SwiftUI

struct SettingsSheet: View {
    @Environment(RemoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var away = ""
    @State private var awayError = false
    @State private var shakes = 0
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                if let pc = store.pc {
                    Section("PC") {
                        LabeledContent("Name", value: pc.name)
                        LabeledContent("Home address", value: "\(pc.host):\(pc.port)").monospacedDigit()
                        LabeledContent("Status", value: store.statusText)
                    }
                    Section {
                        TextField("100.x.y.z", text: $away)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .monospacedDigit()
                            .shake(shakes)
                    } header: {
                        Text("Away address")
                    } footer: {
                        Text(awayError
                             ? "Enter an IPv4 address like 100.101.102.103."
                             : "Your PC's Tailscale IP. When the home address can't be reached, Dockie Remote tries this one. Use the IP, not the MagicDNS name.")
                            .foregroundStyle(awayError ? .red : .secondary)
                    }
                    Section {
                        Button("Forget PC", role: .destructive) { confirmForget = true }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold) }
            }
            .confirmationDialog("Forget \(store.pc?.name ?? "this PC")?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget PC", role: .destructive) {
                    dismiss()
                    store.forgetPC()
                }
            } message: {
                Text("You'll need to pair again to reconnect.")
            }
            .onAppear { away = store.pc?.awayHost ?? "" }
        }
    }

    private func save() {
        let trimmed = away.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && !SavedPC.isIPv4(trimmed) {
            awayError = true
            shakes += 1
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        store.setAwayHost(trimmed)
        dismiss()
    }
}
