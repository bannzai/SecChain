import SecChainCore
import SwiftUI

/// Sheet for making a custom scope appear in the list so that its first secret can be added. The
/// name follows the rules of `CustomScopeName`, the ones `secchain set --scope` applies on a Mac, so
/// that a scope created here is the same scope there. Which repositories get the scope is decided
/// by `~/.secchain` on each Mac (documents/PROJECT.md, "The user's definition file"): the macOS app
/// sets it in each repository's settings, and iOS has no such file, so this sheet asks for the name
/// only.
struct AddScopeView: View {
    /// Called with the chosen scope.
    let add: (SecretScope) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The name as typed, validated by `CustomScopeName` only when it is used.
    @State private var rawName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Only the entered name is monospaced; the Mac shows the label beside it. The
                    // prompt is a scope name, which is the same in every language.
                    TextField(text: $rawName, prompt: Text(verbatim: "youtube")) {
                        Text("Name", bundle: .module)
                            .font(.body)
                    }
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                } footer: {
                    Text(
                        rawName.isEmpty || CustomScopeName(rawName: rawName) != nil
                            ? String(localized: "A Mac passes the secrets of a scope to the repositories its ~/.secchain allows", bundle: .module)
                            : String(localized: "Use lowercase letters, digits and hyphens, starting with a letter or a digit; 'user' and 'repository' are built in", bundle: .module)
                    )
                    .foregroundStyle(rawName.isEmpty || CustomScopeName(rawName: rawName) != nil ? Color.secondary : Color.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Add Scope", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add", bundle: .module)) {
                        if let customScopeName = CustomScopeName(rawName: rawName) {
                            add(.shared(.custom(customScopeName)))
                            dismiss()
                        }
                    }
                    .disabled(CustomScopeName(rawName: rawName) == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 240)
        #endif
    }
}
