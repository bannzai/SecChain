import SecChainCore
import SwiftUI

/// Settings of one repository that belong to this Mac: the shared scopes `secchain run` passes to
/// it, which the `@allow` lines of `~/.secchain` decide (documents/PROJECT.md, "The user's
/// definition file"). Only the macOS app offers it, because only the Mac has that file.
struct RepositorySettingsView: View {
    /// Reads and edits `~/.secchain`.
    let model: AppModel
    /// The repository whose settings are shown.
    let repositoryIdentity: RepositoryIdentity

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let userDefinitionErrorDescription = model.userDefinitionErrorDescription {
                    Section {
                        Label(userDefinitionErrorDescription, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(model.sharedScopes, id: \.self) { sharedScope in
                        passedScopeToggle(sharedScope: sharedScope)
                    }
                } header: {
                    Text("Passed Scopes", bundle: .module)
                } footer: {
                    Text("secchain run passes the secrets of the scopes turned on here together with the repository's own. The setting is kept in ~/.secchain on this Mac", bundle: .module)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Repository Settings", bundle: .module))
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
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }

    /// A switch for the `@allow` line that names this repository alone. A wildcard that also names it
    /// is not this repository's to remove, so the switch is then shown on and locked, with the
    /// pattern that passes the scope.
    func passedScopeToggle(sharedScope: SharedScope) -> some View {
        let wildcardAllowPattern = model.wildcardAllowPattern(sharedScope: sharedScope, repositoryIdentity: repositoryIdentity)
        return Toggle(
            isOn: Binding(
                get: { model.isPassed(sharedScope: sharedScope, repositoryIdentity: repositoryIdentity) },
                set: { isPassed in
                    model.setPassing(sharedScope: sharedScope, repositoryIdentity: repositoryIdentity, isPassed: isPassed)
                }
            )
        ) {
            Text(scopeTitle(scope: .shared(sharedScope)))
            if let wildcardAllowPattern {
                Text("Passed by '@allow \(wildcardAllowPattern)'. Edit ~/.secchain to change it", bundle: .module)
            }
        }
        .disabled(model.userDefinition == nil || wildcardAllowPattern != nil)
    }
}
