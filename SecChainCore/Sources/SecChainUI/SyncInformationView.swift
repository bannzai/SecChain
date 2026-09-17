import SwiftUI

/// Explains how synchronization works and what it needs. The app cannot observe whether iCloud
/// Keychain is enabled, so this screen states conditions instead of claiming a status.
struct SyncInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("How secrets reach your other devices") {
                    Label("SecChain stores secrets in the system Keychain and nowhere else", systemImage: "key")
                    Label("Secrets marked iCloud Keychain are synchronized by the system, end-to-end encrypted", systemImage: "icloud")
                    Label("This device only and device-bound secrets never leave this device", systemImage: "desktopcomputer")
                }
                Section("What synchronization needs") {
                    Label("The same Apple Account on every device", systemImage: "person.crop.circle")
                    Label("iCloud Keychain turned on in the Apple Account settings of every device", systemImage: "switch.2")
                    Label("SecChain installed from the same developer on every device", systemImage: "checkmark.seal")
                }
                Section {
                    Button("Open Settings", systemImage: "gear", action: openAppleAccountSettings)
                } footer: {
                    Text("SecChain cannot see whether iCloud Keychain is on. When it is off, every secret simply stays on this device and keeps working here.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("About Sync")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        // The height of the whole explanation, so that its last statement (what happens when
        // iCloud Keychain is off) is visible without scrolling.
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}
