import SecChainCore
import SwiftUI

/// The secrets of one repository: names and settings only. Values appear solely in
/// `RevealedValueView`, after an explicit action and authentication.
struct RepositoryDetailView: View {
    let model: AppModel
    let repositoryIdentity: RepositoryIdentity

    @State private var isAddingSecret = false
    @State private var storedSecretBeingUpdated: StoredSecret?
    @State private var storedSecretBeingProtected: StoredSecret?
    @State private var storedSecretBeingDeleted: StoredSecret?
    @State private var revealedSecret: RevealedSecret?

    /// A revealed value together with the secret it belongs to, as the sheet's item. Kept out of
    /// `AppModel` so that the value is released as soon as the sheet goes away.
    struct RevealedSecret: Identifiable {
        let storedSecret: StoredSecret
        let value: SecretValue

        var id: String {
            storedSecret.id
        }
    }

    var storedSecrets: [StoredSecret] {
        model.storedSecretsByRepository[repositoryIdentity] ?? []
    }

    var body: some View {
        List {
            #if os(iOS)
            Section {
                secretRows
            } footer: {
                MacOnlySecretsNote()
            }
            #else
            secretRows
            #endif
        }
        .navigationTitle(repositoryIdentity.value)
        #if os(iOS)
        // A repository identifier is too long for a large title on an iPhone and would be cut off.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if storedSecrets.isEmpty {
                ContentUnavailableView(
                    String(localized: "No secrets yet", bundle: .module),
                    systemImage: "key",
                    description: Text("Add the first secret of this repository", bundle: .module)
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Add Secret", bundle: .module), systemImage: "plus") {
                    isAddingSecret = true
                }
            }
        }
        .sheet(isPresented: $isAddingSecret) {
            SecretEditorView(model: model, mode: .add(repositoryIdentity: repositoryIdentity))
        }
        .sheet(item: $storedSecretBeingUpdated) { storedSecret in
            SecretEditorView(model: model, mode: .updateValue(storedSecret: storedSecret))
        }
        .sheet(item: $storedSecretBeingProtected) { storedSecret in
            SecretEditorView(model: model, mode: .changeProtection(storedSecret: storedSecret))
        }
        .sheet(item: $revealedSecret) { revealedSecret in
            RevealedValueView(storedSecret: revealedSecret.storedSecret, value: revealedSecret.value)
        }
        // The title names the secret; iOS hides a dialog's title unless it is made visible.
        .confirmationDialog(
            String(localized: "Delete \(storedSecretBeingDeleted?.name.value ?? "")?", bundle: .module),
            isPresented: Binding(
                get: { storedSecretBeingDeleted != nil },
                set: { isPresented in
                    if !isPresented {
                        storedSecretBeingDeleted = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: storedSecretBeingDeleted
        ) { storedSecret in
            Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                Task {
                    _ = await model.delete(storedSecret: storedSecret)
                }
            }
        } message: { storedSecret in
            Text(
                storedSecret.isSynchronized
                    ? String(localized: "The secret is synchronized, so it is deleted on all your devices", bundle: .module)
                    : String(localized: "The value cannot be recovered", bundle: .module)
            )
        }
    }

    /// One row per secret: its name and settings, with the actions in a menu.
    var secretRows: some View {
        ForEach(storedSecrets) { storedSecret in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storedSecret.name.value)
                        .font(.body.monospaced())
                    HStack(spacing: 12) {
                        Label(protectionLevelTitle(protectionLevel: storedSecret.protectionLevel), systemImage: protectionLevelSymbol(protectionLevel: storedSecret.protectionLevel))
                        Label(
                            storedSecret.isSynchronized
                                ? String(localized: "iCloud Keychain", bundle: .module)
                                : String(localized: "This device only", bundle: .module),
                            systemImage: storedSecret.isSynchronized ? "icloud" : "desktopcomputer"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(String(localized: "Reveal Value", bundle: .module), systemImage: "eye") {
                        reveal(storedSecret: storedSecret)
                    }
                    Button(String(localized: "Update Value", bundle: .module), systemImage: "pencil") {
                        storedSecretBeingUpdated = storedSecret
                    }
                    Button(String(localized: "Change Protection", bundle: .module), systemImage: "lock.shield") {
                        storedSecretBeingProtected = storedSecret
                    }
                    Divider()
                    Button(String(localized: "Delete", bundle: .module), systemImage: "trash", role: .destructive) {
                        storedSecretBeingDeleted = storedSecret
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(String(localized: "Actions for \(storedSecret.name.value)", bundle: .module))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.vertical, 4)
        }
    }

    func reveal(storedSecret: StoredSecret) {
        Task {
            if let value = await model.revealedValue(storedSecret: storedSecret) {
                revealedSecret = RevealedSecret(storedSecret: storedSecret, value: value)
            }
        }
    }
}

func protectionLevelTitle(protectionLevel: ProtectionLevel) -> String {
    switch protectionLevel {
    case .standard: String(localized: "Standard", bundle: .module)
    case .confirm: String(localized: "Confirm", bundle: .module)
    case .deviceBound: String(localized: "Device-bound", bundle: .module)
    }
}

func protectionLevelSymbol(protectionLevel: ProtectionLevel) -> String {
    switch protectionLevel {
    case .standard: "lock.open"
    case .confirm: "touchid"
    case .deviceBound: "lock.shield"
    }
}

func protectionLevelExplanation(protectionLevel: ProtectionLevel) -> String {
    switch protectionLevel {
    case .standard:
        String(localized: "secchain run reads the secret without asking. Revealing the value here still asks for authentication.", bundle: .module)
    case .confirm:
        String(localized: "secchain run asks for Touch ID or your password every time. The secret can still synchronize.", bundle: .module)
    case .deviceBound:
        String(localized: "The Keychain itself demands authentication for every read. The secret never leaves this device and is not restored onto a new one.", bundle: .module)
    }
}
