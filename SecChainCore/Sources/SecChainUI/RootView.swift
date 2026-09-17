import SecChainCore
import SwiftUI

/// Root of both apps: repositories on the left, the selected repository's secrets on the right
/// (a navigation stack on iPhone).
public struct RootView: View {
    @State private var model: AppModel
    @State private var isAddingRepository = false
    @State private var isShowingSyncInformation = false
    @State private var isShowingRemoteApprovalChecks = false

    public init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            if model.isKeychainUnreachable {
                KeychainUnreachableView(model: model)
            } else {
                navigation
            }
        }
        .task {
            model.reload()
        }
        .alert(
            String(localized: "Something went wrong", bundle: .module),
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { isPresented in
                    if !isPresented {
                        model.presentedError = nil
                    }
                }
            ),
            presenting: model.presentedError
        ) { _ in
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: { error in
            Text(error.message(bundle: .module))
        }
    }

    var navigation: some View {
        NavigationSplitView {
            List(selection: $model.selectedRepositoryIdentity) {
                #if os(iOS)
                Section {
                    repositoryRows
                } footer: {
                    MacOnlySecretsNote()
                }
                #else
                repositoryRows
                #endif
            }
            .navigationTitle(String(localized: "Repositories", bundle: .module))
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            #endif
            .overlay {
                if model.repositoryIdentities.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No repositories yet", bundle: .module),
                        systemImage: "key",
                        description: Text("Add a repository to store its first secret", bundle: .module)
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "Add Repository", bundle: .module), systemImage: "plus") {
                        isAddingRepository = true
                    }
                }
                #if os(macOS)
                // The sidebar's toolbar is narrow on the Mac: with more than the sidebar toggle and
                // one other item, Add Repository is pushed into the overflow menu. iOS already
                // gathers secondary actions in a menu.
                ToolbarItem(placement: .secondaryAction) {
                    Menu(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle") {
                        moreActions
                    }
                }
                #else
                ToolbarItemGroup(placement: .secondaryAction) {
                    moreActions
                }
                #endif
            }
        } detail: {
            if let selectedRepositoryIdentity = model.selectedRepositoryIdentity {
                RepositoryDetailView(model: model, repositoryIdentity: selectedRepositoryIdentity)
            } else {
                ContentUnavailableView(String(localized: "Select a repository", bundle: .module), systemImage: "folder")
            }
        }
        .sheet(isPresented: $isAddingRepository) {
            AddRepositoryView { repositoryIdentity in
                model.addRepository(repositoryIdentity: repositoryIdentity)
            }
        }
        .sheet(isPresented: $isShowingSyncInformation) {
            SyncInformationView()
        }
        #if DEBUG
        .sheet(isPresented: $isShowingRemoteApprovalChecks) {
            RemoteApprovalChecksView()
        }
        #endif
    }

    /// One row per repository: the last path component tells repositories apart at a glance, the
    /// full identifier follows for disambiguation.
    var repositoryRows: some View {
        ForEach(model.repositoryIdentities, id: \.self) { repositoryIdentity in
            NavigationLink(value: repositoryIdentity) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repositoryIdentity.value.split(separator: "/").last.map(String.init) ?? repositoryIdentity.value)
                            .lineLimit(1)
                        Text(repositoryIdentity.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text("^[\(model.storedSecretsByRepository[repositoryIdentity]?.count ?? 0) secret](inflect: true)", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
        }
    }

    /// Actions needed less often than adding a repository.
    @ViewBuilder
    var moreActions: some View {
        Button(String(localized: "About Sync", bundle: .module), systemImage: "icloud") {
            isShowingSyncInformation = true
        }
        Button(String(localized: "Reload", bundle: .module), systemImage: "arrow.clockwise", action: model.reload)
        #if DEBUG
        // Also offered outside the unreachable screen because a build that reaches the Keychain
        // (the iOS Simulator) never shows that screen, and the simulator cannot answer the
        // authentication that revealing a stored value needs.
        Button("Use Demo Data", systemImage: "tray.full", action: model.useDemoStore)
        // The error alert otherwise needs a real Keychain or authentication failure, which demo
        // data and a remote session cannot produce.
        Button("Show Sample Error", systemImage: "exclamationmark.triangle") {
            model.present(error: SecretStoreError.keychainUnavailable)
        }
        // The Secure Enclave and CloudKit behavior that remote approval depends on differs between
        // the Simulator and a device, and neither can be driven by launch arguments remotely.
        Button("Run Remote Approval Checks", systemImage: "checkmark.shield") {
            isShowingRemoteApprovalChecks = true
        }
        #endif
    }
}

/// Shown instead of the app when the Keychain refuses the binary itself. It explains the cause
/// (code signing) because nothing else in the app can work in that state.
struct KeychainUnreachableView: View {
    /// Checked again on request, and replaced by demo data in debug builds.
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "SecChain cannot reach its Keychain items", bundle: .module), systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(SecretStoreError.missingEntitlement.message(bundle: .module))
        } actions: {
            Button(String(localized: "Try Again", bundle: .module), action: model.reload)
            #if DEBUG
            // A development build signed without SecChain's team lands here; demo data lets such a
            // build show every other screen.
            Button("Use Demo Data", action: model.useDemoStore)
            #endif
        }
        .padding()
    }
}
