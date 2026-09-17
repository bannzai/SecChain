import SwiftUI

/// Explains how synchronization works and what it needs. The app cannot observe whether iCloud
/// Keychain is enabled, so this screen states conditions instead of claiming a status.
struct SyncInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "How secrets reach your other devices", bundle: .module)) {
                    Label(String(localized: "SecChain stores secrets in the system Keychain and nowhere else", bundle: .module), systemImage: "key")
                    Label(String(localized: "Secrets marked iCloud Keychain are synchronized by the system, end-to-end encrypted", bundle: .module), systemImage: "icloud")
                    Label(String(localized: "This device only and device-bound secrets never leave this device", bundle: .module), systemImage: "desktopcomputer")
                }
                Section(String(localized: "What synchronization needs", bundle: .module)) {
                    Label(String(localized: "The same Apple Account on every device", bundle: .module), systemImage: "person.crop.circle")
                    Label(String(localized: "iCloud Keychain turned on in the Apple Account settings of every device", bundle: .module), systemImage: "switch.2")
                    Label(String(localized: "SecChain installed from the same developer on every device", bundle: .module), systemImage: "checkmark.seal")
                }
                Section {
                    Button(String(localized: "Open Settings", bundle: .module), systemImage: "gear", action: openAppleAccountSettings)
                } footer: {
                    Text("SecChain cannot see whether iCloud Keychain is on. When it is off, every secret simply stays on this device and keeps working here.", bundle: .module)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "About Sync", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) {
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
