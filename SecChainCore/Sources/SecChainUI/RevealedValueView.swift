import SecChainCore
import SwiftUI

/// Shows one value after the owner authenticated. The value hides itself again after a short
/// time, so that a window left open does not keep a secret on screen.
struct RevealedValueView: View {
    let storedSecret: StoredSecret
    let value: SecretValue

    /// Long enough to read or copy a value, short enough that a forgotten sheet does not leave
    /// it on screen during a meeting or a screen share.
    static let visibleDuration = Duration.seconds(30)

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(value.exposedString ?? String(localized: "This value is not text and cannot be displayed", bundle: .module))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .privacySensitive()
                } footer: {
                    Text("Hidden again after 30 seconds", bundle: .module)
                }
                Section {
                    Button(
                        didCopy ? String(localized: "Copied", bundle: .module) : String(localized: "Copy", bundle: .module),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    ) {
                        if let text = value.exposedString {
                            copyConcealed(text: text)
                            didCopy = true
                        }
                    }
                    .disabled(value.exposedString == nil)
                } footer: {
                    // Each platform protects the copy differently (see `copyConcealed(text:)`).
                    #if os(macOS)
                    Text("The copy is marked as a password so that clipboard managers skip it", bundle: .module)
                    #else
                    Text("The copy stays on this device and is removed from the clipboard after one minute", bundle: .module)
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle(storedSecret.name.value)
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
            .task {
                try? await Task.sleep(for: Self.visibleDuration)
                dismiss()
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 240)
        #endif
    }
}
