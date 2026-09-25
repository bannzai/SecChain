import Foundation
import SecChainCore

#if os(iOS)
import UIKit
#endif

/// Builds the model an app starts with.
public enum AppModelFactory {
    /// The real Keychain, with authentication reasons in the app's language. A debug build can
    /// switch to demo data later (`AppModel.useDemoStore()`).
    public static func make() -> AppModel {
        #if os(macOS)
        AppModel(
            store: systemStore(),
            readUserDefinitionText: { try UserDefinitionFile.readText(homeDirectory: UserDefinitionFile.homeDirectory) },
            writeUserDefinitionText: { try UserDefinitionFile.write(text: $0, homeDirectory: UserDefinitionFile.homeDirectory) }
        )
        #else
        // The iOS app has no `~/.secchain`: it never runs a command, so it never needs to know which
        // scopes a repository gets, and it shows no control that edits the file.
        AppModel(store: systemStore(), readUserDefinitionText: { nil }, writeUserDefinitionText: { _ in })
        #endif
    }

    /// The real Keychain, with authentication reasons in the app's language.
    static func systemStore() -> SecretStore {
        SecretStore(
            keychain: SystemSecretKeychain(),
            ownerAuthenticator: SystemOwnerAuthenticator(),
            authenticationReasonBundle: .module
        )
    }

    #if os(iOS)
    /// The model of the remote approval screens, which only the iOS app has: approving is what the
    /// paired iPhone does (issue #39).
    public static func makeRemoteApprovalModel() -> RemoteApprovalModel {
        RemoteApprovalModel(
            makeStore: CloudKitRemoteApprovalStore.system,
            keyStore: SecureEnclaveRemoteApprovalKeyStore(
                authenticationReason: String(localized: "approve a request from your Mac", bundle: .module)
            ),
            // Without the user-assigned device name entitlement this is the model name ("iPhone"),
            // which is what the Mac shows next to the key while pairing. SecChain does not ask for
            // that entitlement: the number both screens compare is what identifies the key, and the
            // name only helps the user recognize the device.
            deviceName: UIDevice.current.name,
            notifying: SystemRemoteApprovalNotifying(),
            installSubscription: RemoteApprovalSubscription.install(alertTitle:alertBody:)
        )
    }
    #endif

    #if DEBUG
    /// Authenticator of the demo store: succeeds without a prompt, so that reveal can be shown.
    struct AlwaysAuthenticatedOwnerAuthenticator: OwnerAuthenticating {
        func authenticate(reason: String) async throws -> OwnerAuthentication {
            OwnerAuthentication(context: nil)
        }
    }

    /// In-memory secrets with dummy values, for screenshots and UI checks: populated screens
    /// without touching the Keychain and without a signed build.
    static func demoStore() -> SecretStore {
        let keychain = InMemorySecretKeychain()
        let demoSecrets: [(scope: SecretScope?, name: String, protectionLevel: ProtectionLevel, isSynchronized: Bool)] = [
            (.repository(RepositoryIdentity(value: "github.com/example/web-app")), "OPENAI_API_KEY", .standard, true),
            (.repository(RepositoryIdentity(value: "github.com/example/web-app")), "CLOUDFLARE_API_TOKEN", .confirm, true),
            (.repository(RepositoryIdentity(value: "github.com/example/web-app")), "DATABASE_URL", .standard, false),
            (.repository(RepositoryIdentity(value: "github.com/example/web-app")), "SIGNING_KEY_PASSWORD", .deviceBound, false),
            (.repository(RepositoryIdentity(value: "github.com/example/mobile-app")), "FIREBASE_TOKEN", .standard, true),
            (.repository(RepositoryIdentity(value: "my-notes")), "BLOG_API_KEY", .standard, true),
            (.shared(.user), "ANTHROPIC_API_KEY", .standard, true),
            (SharedScope(name: "youtube").map(SecretScope.shared), "YOUTUBE_API_KEY", .confirm, true),
            // A scope that only the Keychain knows, as one created on another Mac arrives.
            (SharedScope(name: "newsletter").map(SecretScope.shared), "NEWSLETTER_API_KEY", .standard, true),
        ]
        for demoSecret in demoSecrets {
            guard let scope = demoSecret.scope, let name = SecretName(rawName: demoSecret.name) else {
                continue
            }
            try? keychain.write(
                storedSecret: StoredSecret(
                    scope: scope,
                    name: name,
                    protectionLevel: demoSecret.protectionLevel,
                    isSynchronized: demoSecret.isSynchronized,
                    modificationDate: nil
                ),
                value: SecretValue(exposingString: "dummy-value-for-demo"),
                replacing: nil,
                ownerAuthentication: nil
            )
        }
        return SecretStore(keychain: keychain, ownerAuthenticator: AlwaysAuthenticatedOwnerAuthenticator())
    }

    /// `~/.secchain` of the demo data: the user scope passed to every example repository through a
    /// wildcard, a custom scope passed to one of them, and a custom scope that only the file names.
    static let demoUserDefinitionText = """
        # user scope
        ANTHROPIC_API_KEY
        @allow github.com/example/*

        @scope youtube
        YOUTUBE_API_KEY
        @allow github.com/example/web-app

        @scope design

        """
    #endif
}
