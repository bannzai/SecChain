import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Puts text on the pasteboard in the way each platform offers for passwords.
func copyConcealed(text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    // Convention honored by clipboard managers (nspasteboard.org): content carrying this type is
    // not recorded in their history.
    NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    #else
    UIPasteboard.general.setItems(
        [[UIPasteboard.typeAutomatic: text]],
        options: [
            // Stays on this device (no Universal Clipboard) and disappears by itself. One minute
            // is enough to switch apps and paste.
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(60),
        ]
    )
    #endif
}

/// Opens the system's Apple Account settings, where iCloud Keychain is turned on.
func openAppleAccountSettings() {
    #if os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
        NSWorkspace.shared.open(url)
    }
    #else
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
    #endif
}
