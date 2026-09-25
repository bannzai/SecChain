import SecChainCore
import SwiftUI

/// Sheet for making a custom scope appear in the list so that its first secret can be added. Only
/// the name is asked for: which repositories get the scope is chosen in each repository's
/// settings.
struct AddCustomScopeView: View {
    /// Called with the entered name.
    let add: (CustomScopeName) -> Void

    @Environment(\.dismiss) private var dismiss
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
                            ? String(localized: "A custom scope holds secrets that several repositories share", bundle: .module)
                            : String(localized: "Use lowercase letters, digits and hyphens, starting with a letter or a digit. 'user' and 'repository' are built in", bundle: .module)
                    )
                    .foregroundStyle(rawName.isEmpty || CustomScopeName(rawName: rawName) != nil ? Color.secondary : Color.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Add Custom Scope", bundle: .module))
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
                            add(customScopeName)
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
