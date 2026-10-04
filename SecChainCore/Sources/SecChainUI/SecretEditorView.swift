import SecChainCore
import SwiftUI

/// Sheet for adding a secret, replacing a value, changing how a secret is protected, or writing its
/// note.
struct SecretEditorView: View {
    /// What the sheet edits. One view serves all four because adding a secret shows the controls of
    /// each of the others, with their explanations.
    enum Mode {
        case add(scope: SecretScope)
        case updateValue(storedSecret: StoredSecret)
        case changeProtection(storedSecret: StoredSecret)
        case editNote(storedSecret: StoredSecret)
    }

    let model: AppModel
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var rawName = ""
    @State private var valueText = ""
    @State private var protectionLevel = ProtectionLevel.standard
    @State private var isSynchronized = true
    @State private var noteText = ""
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
                if showsValue {
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
                if showsProtection {
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
                if showsNote {
                    Section {
                        TextField(text: $noteText, prompt: Text("What the secret is for", bundle: .module)) {
                            Text("Note", bundle: .module)
                                .font(.body)
                        }
                    } footer: {
                        Text(
                            isNoteAcceptable
                                ? String(localized: "Never write a value here: every app and secchain list show the note", bundle: .module)
                                : String(localized: "Use one line without tabs", bundle: .module)
                        )
                        .foregroundStyle(isNoteAcceptable ? Color.secondary : Color.red)
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

    /// Whether the sheet asks for a value: when adding a secret and when replacing its value.
    var showsValue: Bool {
        switch mode {
        case .add, .updateValue: true
        case .changeProtection, .editNote: false
        }
    }

    /// Whether the sheet offers the protection level and synchronization.
    var showsProtection: Bool {
        switch mode {
        case .add, .changeProtection: true
        case .updateValue, .editNote: false
        }
    }

    /// Whether the sheet offers the note. Replacing a value or changing the protection keeps it.
    var showsNote: Bool {
        switch mode {
        case .add, .editNote: true
        case .updateValue, .changeProtection: false
        }
    }

    /// The note as entered, `nil` for a field left empty, which removes the note. Whitespace around
    /// it is dropped, so that a note of spaces alone counts as empty rather than invalid.
    var enteredNote: SecretNote? {
        SecretNote(rawNote: noteText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the field holds a note `SecretNote` accepts, or nothing.
    var isNoteAcceptable: Bool {
        noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || enteredNote != nil
    }

    var title: String {
        switch mode {
        case .add: String(localized: "Add Secret", bundle: .module)
        case .updateValue(let storedSecret): String(localized: "Update \(storedSecret.name.value)", bundle: .module)
        case .changeProtection(let storedSecret): String(localized: "Protection of \(storedSecret.name.value)", bundle: .module)
        case .editNote(let storedSecret): String(localized: "Note of \(storedSecret.name.value)", bundle: .module)
        }
    }

    var canSave: Bool {
        switch mode {
        case .add: isValidSecretName(name: rawName) && !valueText.isEmpty && isNoteAcceptable
        case .updateValue: !valueText.isEmpty
        case .changeProtection: true
        case .editNote: isNoteAcceptable
        }
    }

    func loadCurrentSettings() {
        switch mode {
        case .add:
            break
        case .updateValue(let storedSecret), .changeProtection(let storedSecret):
            protectionLevel = storedSecret.protectionLevel
            isSynchronized = storedSecret.isSynchronized
        case .editNote(let storedSecret):
            noteText = storedSecret.note?.value ?? ""
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
                    isSynchronized: isSynchronized,
                    note: enteredNote
                )
            case .updateValue(let storedSecret):
                succeeded = await model.save(
                    name: storedSecret.name,
                    value: SecretValue(exposingString: valueText),
                    scope: storedSecret.scope,
                    protectionLevel: storedSecret.protectionLevel,
                    isSynchronized: storedSecret.isSynchronized,
                    note: nil
                )
            case .changeProtection(let storedSecret):
                succeeded = await model.changeProtection(
                    storedSecret: storedSecret,
                    protectionLevel: protectionLevel,
                    isSynchronized: isSynchronized
                )
            case .editNote(let storedSecret):
                succeeded = await model.saveNote(storedSecret: storedSecret, note: enteredNote)
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
