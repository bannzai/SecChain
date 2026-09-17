import Foundation
import LocalAuthentication

/// Proof that the device owner was authenticated just now. It wraps the evaluated `LAContext`
/// because the Keychain accepts that context for device-bound items, which is what lets one
/// prompt cover several secrets.
public struct OwnerAuthentication: @unchecked Sendable {
    /// `nil` only for test doubles. `LAContext` is not `Sendable`; it is never mutated after
    /// evaluation and only handed to `SecItem` calls, which is why the wrapper is unchecked.
    public let context: LAContext?

    public init(context: LAContext?) {
        self.context = context
    }
}

/// Asks the device owner to authenticate. A protocol so that the policy in `SecretStore` can be
/// unit-tested without a prompt.
public protocol OwnerAuthenticating: Sendable {
    /// Shows the system prompt (Touch ID / Face ID / Apple Watch / password).
    /// Throws `SecretStoreError` when the user does not authenticate.
    func authenticate(reason: String) async throws -> OwnerAuthentication
}

/// The real authenticator, backed by LocalAuthentication.
public struct SystemOwnerAuthenticator: OwnerAuthenticating {
    public init() {}

    public func authenticate(reason: String) async throws -> OwnerAuthentication {
        let context = LAContext()
        do {
            // `.deviceOwnerAuthentication` falls back to the password, so Macs without Touch ID
            // and sessions with the lid closed can still authenticate.
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw SecretStoreErrorMapping.error(
                localAuthenticationErrorCode: (error as NSError).code,
                message: error.localizedDescription
            )
        }
        return OwnerAuthentication(context: context)
    }
}
