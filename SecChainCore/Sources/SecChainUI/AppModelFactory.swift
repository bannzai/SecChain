import Foundation
import SecChainCore

/// Builds the model an app starts with.
public enum AppModelFactory {
    /// The real Keychain, unless a debug build is launched with `--demo-data`.
    ///
    /// The demo store exists for screenshots and UI checks: it shows populated screens without
    /// touching the Keychain and without a signed build. It has to be a launch argument rather
    /// than an in-app switch because the choice of store is made before the first screen exists.
    public static func make(arguments: [String]) -> AppModel {
        #if DEBUG
        if arguments.contains("--demo-data") {
            let model = AppModel(store: demoStore())
            if let index = arguments.firstIndex(of: "--demo-screen"), arguments.indices.contains(index + 1) {
                model.demoScreen = arguments[index + 1]
            }
            return model
        }
        #endif
        return AppModel(store: .system)
    }

    #if DEBUG
    /// Authenticator of the demo store: succeeds without a prompt, so that reveal can be shown.
    struct AlwaysAuthenticatedOwnerAuthenticator: OwnerAuthenticating {
        func authenticate(reason: String) async throws -> OwnerAuthentication {
            OwnerAuthentication(context: nil)
        }
    }

    static func demoStore() -> SecretStore {
        let keychain = InMemorySecretKeychain()
        let demoSecrets: [(repository: String, name: String, protectionLevel: ProtectionLevel, isSynchronized: Bool)] = [
            ("github.com/example/web-app", "OPENAI_API_KEY", .standard, true),
            ("github.com/example/web-app", "CLOUDFLARE_API_TOKEN", .confirm, true),
            ("github.com/example/web-app", "DATABASE_URL", .standard, false),
            ("github.com/example/web-app", "SIGNING_KEY_PASSWORD", .deviceBound, false),
            ("github.com/example/mobile-app", "FIREBASE_TOKEN", .standard, true),
            ("my-notes", "BLOG_API_KEY", .standard, true),
        ]
        for demoSecret in demoSecrets {
            guard let name = SecretName(rawName: demoSecret.name) else {
                continue
            }
            try? keychain.write(
                storedSecret: StoredSecret(
                    repositoryIdentity: RepositoryIdentity(value: demoSecret.repository),
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
    #endif
}
