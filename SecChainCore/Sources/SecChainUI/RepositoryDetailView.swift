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
                    "No secrets yet",
                    systemImage: "key",
                    description: Text("Add the first secret of this repository")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Secret", systemImage: "plus") {
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
            "Delete \(storedSecretBeingDeleted?.name.value ?? "")?",
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
            Button("Delete", role: .destructive) {
                Task {
                    _ = await model.delete(storedSecret: storedSecret)
                }
            }
        } message: { storedSecret in
            Text(
                storedSecret.isSynchronized
                    ? "The secret is synchronized, so it is deleted on all your devices"
                    : "The value cannot be recovered"
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
                            storedSecret.isSynchronized ? "iCloud Keychain" : "This device only",
                            systemImage: storedSecret.isSynchronized ? "icloud" : "desktopcomputer"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Reveal Value", systemImage: "eye") {
                        reveal(storedSecret: storedSecret)
                    }
                    Button("Update Value", systemImage: "pencil") {
                        storedSecretBeingUpdated = storedSecret
                    }
                    Button("Change Protection", systemImage: "lock.shield") {
                        storedSecretBeingProtected = storedSecret
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        storedSecretBeingDeleted = storedSecret
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Actions for \(storedSecret.name.value)")
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
    case .standard: "Standard"
    case .confirm: "Confirm"
    case .deviceBound: "Device-bound"
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
        "secchain run reads the secret without asking. Revealing the value here still asks for authentication."
    case .confirm:
        "secchain run asks for Touch ID or your password every time. The secret can still synchronize."
    case .deviceBound:
        "The Keychain itself demands authentication for every read. The secret never leaves this device and is not restored onto a new one."
    }
}
