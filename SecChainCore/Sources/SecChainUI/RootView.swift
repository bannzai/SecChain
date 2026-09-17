import SecChainCore
import SwiftUI

/// Root of both apps: repositories on the left, the selected repository's secrets on the right
/// (a navigation stack on iPhone).
public struct RootView: View {
    @State private var model: AppModel
    @State private var isAddingRepository = false
    @State private var isShowingSyncInformation = false

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
            "Something went wrong",
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
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.description)
        }
    }

    var navigation: some View {
        NavigationSplitView {
            List(model.repositoryIdentities, id: \.self, selection: $model.selectedRepositoryIdentity) { repositoryIdentity in
                NavigationLink(value: repositoryIdentity) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            // The last path component is what tells repositories apart at a
                            // glance; the full identifier follows for disambiguation.
                            Text(repositoryIdentity.value.split(separator: "/").last.map(String.init) ?? repositoryIdentity.value)
                                .lineLimit(1)
                            Text(repositoryIdentity.value)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text("^[\(model.storedSecretsByRepository[repositoryIdentity]?.count ?? 0) secret](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
            .navigationTitle("Repositories")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            #endif
            .overlay {
                if model.repositoryIdentities.isEmpty {
                    ContentUnavailableView(
                        "No repositories yet",
                        systemImage: "key",
                        description: Text("Add a repository to store its first secret")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Repository", systemImage: "plus") {
                        isAddingRepository = true
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("About Sync", systemImage: "icloud") {
                        isShowingSyncInformation = true
                    }
                }
                #if os(macOS)
                // The sidebar's toolbar is narrow on the Mac: one button more pushes Add Repository
                // into the overflow menu. iOS already gathers secondary actions in a menu.
                ToolbarItem(placement: .secondaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
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
                ContentUnavailableView("Select a repository", systemImage: "folder")
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
    }

    /// Actions needed less often than adding a repository.
    @ViewBuilder
    var moreActions: some View {
        Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
        #if DEBUG
        // The error alert otherwise needs a real Keychain or authentication failure, which demo
        // data and a remote session cannot produce.
        Button("Show Sample Error", systemImage: "exclamationmark.triangle") {
            model.present(error: SecretStoreError.keychainUnavailable)
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
            Label("SecChain cannot reach its Keychain items", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(SecretStoreError.missingEntitlement.description)
        } actions: {
            Button("Try Again", action: model.reload)
            #if DEBUG
            // A development build signed without SecChain's team lands here; demo data lets such a
            // build show every other screen.
            Button("Use Demo Data", action: model.useDemoStore)
            #endif
        }
        .padding()
    }
}
