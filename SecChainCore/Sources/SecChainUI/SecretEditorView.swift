import SecChainCore
import SwiftUI

/// Sheet for adding a secret, replacing a value, or changing how a secret is protected.
struct SecretEditorView: View {
    /// What the sheet edits. One view serves all three because they share the protection and
    /// synchronization controls and their explanations.
    enum Mode {
        case add(repositoryIdentity: RepositoryIdentity)
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
                        TextField("Name", text: $rawName, prompt: Text("OPENAI_API_KEY"))
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                    } footer: {
                        Text(
                            rawName.isEmpty || isValidSecretName(name: rawName)
                                ? "The name is also the environment variable that secchain run sets"
                                : "Use letters, digits and underscores, not starting with a digit"
                        )
                        .foregroundStyle(rawName.isEmpty || isValidSecretName(name: rawName) ? Color.secondary : Color.red)
                    }
                }
                if !isChangingProtection {
                    Section {
                        SecureField("Value", text: $valueText)
                            .font(.body.monospaced())
                    } footer: {
                        Text("The value is stored in the Keychain only")
                    }
                }
                if !isUpdatingValue {
                    Section {
                        Picker("Protection", selection: $protectionLevel) {
                            ForEach(ProtectionLevel.allCases, id: \.self) { protectionLevel in
                                Text(protectionLevelTitle(protectionLevel: protectionLevel)).tag(protectionLevel)
                            }
                        }
                        Toggle("Synchronize with iCloud Keychain", isOn: $isSynchronized)
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
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
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
        case .add: "Add Secret"
        case .updateValue(let storedSecret): "Update \(storedSecret.name.value)"
        case .changeProtection(let storedSecret): "Protection of \(storedSecret.name.value)"
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
            case .add(let repositoryIdentity):
                guard let name = SecretName(rawName: rawName) else {
                    isSaving = false
                    return
                }
                succeeded = await model.save(
                    name: name,
                    value: SecretValue(exposingString: valueText),
                    repositoryIdentity: repositoryIdentity,
                    protectionLevel: protectionLevel,
                    isSynchronized: isSynchronized
                )
            case .updateValue(let storedSecret):
                succeeded = await model.save(
                    name: storedSecret.name,
                    value: SecretValue(exposingString: valueText),
                    repositoryIdentity: storedSecret.repositoryIdentity,
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
