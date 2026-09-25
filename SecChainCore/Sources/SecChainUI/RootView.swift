import SecChainCore
import SwiftUI

/// Root of both apps: repositories on the left, the selected repository's secrets on the right
/// (a navigation stack on iPhone).
public struct RootView: View {
    @State private var model: AppModel
    @State private var isAddingRepository = false
    /// Shows `AddCustomScopeView`, offered by the Mac's add menu.
    @State private var isAddingCustomScope = false
    @State private var isShowingSyncInformation = false
    @State private var isShowingRemoteApprovalChecks = false
    #if os(iOS)
    /// Provided by the iOS app, which owns it because a notification reaches the app delegate.
    @Environment(RemoteApprovalModel.self) private var remoteApprovalModel
    @State private var isShowingRemoteApproval = false
    #endif

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
            List(selection: $model.selectedScope) {
                #if os(iOS)
                Section {
                    repositoryRows
                } footer: {
                    MacOnlySecretsNote()
                }
                #else
                Section(String(localized: "Repositories", bundle: .module)) {
                    if model.repositoryIdentities.isEmpty {
                        // A row instead of the overlay iOS shows: the scopes below keep the list
                        // from being empty.
                        Text("Add a repository to store its first secret", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                    repositoryRows
                }
                // Shared scopes come with `~/.secchain`, which only the Mac has; the iOS app gets
                // them in https://github.com/bannzai/SecChain/issues/59.
                Section(String(localized: "Scopes", bundle: .module)) {
                    sharedScopeRows
                    if let userDefinitionErrorDescription = model.userDefinitionErrorDescription {
                        Label(userDefinitionErrorDescription, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            // A sidebar row is one line by default, which would cut off the reason.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #endif
            }
            .navigationTitle(String(localized: "Repositories", bundle: .module))
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            #else
            .overlay {
                if model.repositoryIdentities.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No repositories yet", bundle: .module),
                        systemImage: "key",
                        description: Text("Add a repository to store its first secret", bundle: .module)
                    )
                }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    #if os(macOS)
                    Menu(String(localized: "Add", bundle: .module), systemImage: "plus") {
                        Button(String(localized: "Add Repository", bundle: .module), systemImage: "folder.badge.plus") {
                            isAddingRepository = true
                        }
                        Button(String(localized: "Add Custom Scope", bundle: .module), systemImage: "square.stack.3d.up") {
                            isAddingCustomScope = true
                        }
                    }
                    #else
                    Button(String(localized: "Add Repository", bundle: .module), systemImage: "plus") {
                        isAddingRepository = true
                    }
                    #endif
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
            if let selectedScope = model.selectedScope {
                RepositoryDetailView(model: model, scope: selectedScope)
            } else {
                ContentUnavailableView(String(localized: "Select a repository", bundle: .module), systemImage: "folder")
            }
        }
        .sheet(isPresented: $isAddingRepository) {
            AddRepositoryView { repositoryIdentity in
                model.add(scope: .repository(repositoryIdentity))
            }
        }
        .sheet(isPresented: $isAddingCustomScope) {
            AddCustomScopeView { customScopeName in
                model.add(scope: .shared(.custom(customScopeName)))
            }
        }
        .sheet(isPresented: $isShowingSyncInformation) {
            SyncInformationView()
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingRemoteApproval, onDismiss: remoteApprovalModel.dismissRequest) {
            RemoteApprovalPairingView(model: remoteApprovalModel)
        }
        .onChange(of: remoteApprovalModel.presentedRequest) { _, presentedRequest in
            // A request found when the app opens, or after a notification, shows itself: answering
            // it is what the user came for, and the Mac waits only two minutes.
            if presentedRequest != nil {
                isShowingRemoteApproval = true
            }
        }
        #endif
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
            NavigationLink(value: SecretScope.repository(repositoryIdentity)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repositoryIdentity.value.split(separator: "/").last.map(String.init) ?? repositoryIdentity.value)
                            .lineLimit(1)
                        Text(repositoryIdentity.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text("^[\(model.storedSecretsByScope[.repository(repositoryIdentity)]?.count ?? 0) secret](inflect: true)", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
        }
    }

    /// One row per shared scope: the user scope first, then the custom scopes (`AppModel.sharedScopes`).
    var sharedScopeRows: some View {
        ForEach(model.sharedScopes, id: \.self) { sharedScope in
            NavigationLink(value: SecretScope.shared(sharedScope)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scopeTitle(scope: .shared(sharedScope)))
                            .lineLimit(1)
                        Text("^[\(model.storedSecretsByScope[.shared(sharedScope)]?.count ?? 0) secret](inflect: true)", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: sharedScope == .user ? "person" : "square.stack.3d.up")
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
        #if os(iOS)
        // Only the iPhone and iPad answer an approval; the macOS app has no approval screen
        // (issue #39).
        Button(String(localized: "Remote Approval", bundle: .module), systemImage: "checkmark.shield") {
            isShowingRemoteApproval = true
        }
        #endif
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
        #if os(macOS)
        // An unreadable `~/.secchain` otherwise needs a broken file in the home directory of the
        // Mac the app runs on, which a remote session cannot write.
        Button("Show Sample ~/.secchain Error", systemImage: "exclamationmark.octagon") {
            model.showSampleUserDefinitionError()
        }
        #endif
        // The Secure Enclave and CloudKit behavior that remote approval depends on differs between
        // the Simulator and a device, and neither can be driven by launch arguments remotely.
        Button("Run Remote Approval Checks", systemImage: "list.bullet.clipboard") {
            isShowingRemoteApprovalChecks = true
        }
        #if os(iOS)
        // The Simulator has neither an Apple Account nor a Secure Enclave key that requires Face
        // ID, so the approval and pairing screens are filled from here instead.
        Button("Use Demo Remote Approval", systemImage: "iphone.gen3.badge.checkmark") {
            Task {
                await remoteApprovalModel.useDemoData()
            }
        }
        #endif
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
