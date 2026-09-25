#if os(iOS)
import SecChainCore
import SwiftUI

/// Sheet for making a custom scope appear in the list so that its first secret can be added. The
/// name follows the rules of `CustomScopeName`, the ones `secchain set --scope` applies on a Mac, so
/// that a scope created here is the same scope there. Which repositories get the scope is decided
/// by `~/.secchain` on each Mac, which iOS does not have (documents/PROJECT.md, "The user's
/// definition file"), so this sheet asks for the name only.
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
                    // Only the entered name is monospaced. The prompt is a scope name, which is the
                    // same in every language.
                    TextField(text: $rawName, prompt: Text(verbatim: "youtube")) {
                        Text("Name", bundle: .module)
                            .font(.body)
                    }
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
            .navigationBarTitleDisplayMode(.inline)
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
    }
}
#endif
