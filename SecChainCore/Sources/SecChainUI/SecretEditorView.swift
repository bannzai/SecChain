import SecChainCore
import SwiftUI

/// Sheet for adding a secret, replacing a value, or changing how a secret is protected.
struct SecretEditorView: View {
    /// What the sheet edits. One view serves all three because they share the protection and
    /// synchronization controls and their explanations.
    enum Mode {
        case add(scope: SecretScope)
        case updateValue(storedSecret: StoredSecret)
        case changeProtection(storedSecret: StoredSecret)
    }

    let model: AppModel
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var rawName = ""
    @State private var valueText = ""
    @State private var protectionLevel = ProtectionLevel.standard
    @State private var isSynchronized = true
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                if case .add = mode {
                    Section {
                        // Only the entered name is monospaced; the Mac shows the label beside it.
                        // The prompt is an environment variable name, which is the same in every
                        // language.
                        TextField(text: $rawName, prompt: Text(verbatim: "OPENAI_API_KEY")) {
                            Text("Name", bundle: .module)
                                .font(.body)
                        }
                        .font(.body.monospaced())
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                    } footer: {
                        Text(
                            rawName.isEmpty || isValidSecretName(name: rawName)
                                ? String(localized: "The name is also the environment variable that secchain run sets", bundle: .module)
                                : String(localized: "Use letters, digits and underscores, not starting with a digit", bundle: .module)
                        )
                        .foregroundStyle(rawName.isEmpty || isValidSecretName(name: rawName) ? Color.secondary : Color.red)
                    }
                }
                if !isChangingProtection {
                    Section {
                        SecureField(text: $valueText) {
                            Text("Value", bundle: .module)
                                .font(.body)
                        }
                        .font(.body.monospaced())
                    } footer: {
                        Text("The value is stored in the Keychain only", bundle: .module)
                    }
                }
                if !isUpdatingValue {
                    Section {
                        Picker(String(localized: "Protection", bundle: .module), selection: $protectionLevel) {
                            ForEach(ProtectionLevel.allCases, id: \.self) { protectionLevel in
                                Text(protectionLevelTitle(protectionLevel: protectionLevel)).tag(protectionLevel)
                            }
                        }
                        Toggle(String(localized: "Synchronize with iCloud Keychain", bundle: .module), isOn: $isSynchronized)
                            .disabled(protectionLevel == .deviceBound)
                    } footer: {
                        Text(protectionLevelExplanation(protectionLevel: protectionLevel))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
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
                    Button(String(localized: "Save", bundle: .module), action: save)
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear(perform: loadCurrentSettings)
            .onChange(of: protectionLevel) { _, newProtectionLevel in
                if newProtectionLevel == .deviceBound {
                    isSynchronized = false
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }

    var isChangingProtection: Bool {
        if case .changeProtection = mode {
            return true
        }
        return false
    }

    var isUpdatingValue: Bool {
        if case .updateValue = mode {
            return true
        }
        return false
    }

    var title: String {
        switch mode {
        case .add: String(localized: "Add Secret", bundle: .module)
        case .updateValue(let storedSecret): String(localized: "Update \(storedSecret.name.value)", bundle: .module)
        case .changeProtection(let storedSecret): String(localized: "Protection of \(storedSecret.name.value)", bundle: .module)
        }
    }

    var canSave: Bool {
        switch mode {
        case .add: isValidSecretName(name: rawName) && !valueText.isEmpty
        case .updateValue: !valueText.isEmpty
        case .changeProtection: true
        }
    }

    func loadCurrentSettings() {
        switch mode {
        case .add:
            break
        case .updateValue(let storedSecret), .changeProtection(let storedSecret):
            protectionLevel = storedSecret.protectionLevel
            isSynchronized = storedSecret.isSynchronized
        }
    }

    func save() {
        isSaving = true
        Task {
            let succeeded: Bool
            switch mode {
            case .add(let scope):
                guard let name = SecretName(rawName: rawName) else {
                    isSaving = false
                    return
                }
                succeeded = await model.save(
                    name: name,
                    value: SecretValue(exposingString: valueText),
                    scope: scope,
                    protectionLevel: protectionLevel,
                    isSynchronized: isSynchronized
                )
            case .updateValue(let storedSecret):
                succeeded = await model.save(
                    name: storedSecret.name,
                    value: SecretValue(exposingString: valueText),
                    scope: storedSecret.scope,
                    protectionLevel: storedSecret.protectionLevel,
                    isSynchronized: storedSecret.isSynchronized
                )
            case .changeProtection(let storedSecret):
                succeeded = await model.changeProtection(
                    storedSecret: storedSecret,
                    protectionLevel: protectionLevel,
                    isSynchronized: isSynchronized
                )
            }
            isSaving = false
            if succeeded {
                // The text field's copy of the value is dropped together with the sheet.
                valueText = ""
                dismiss()
            }
        }
    }
}
