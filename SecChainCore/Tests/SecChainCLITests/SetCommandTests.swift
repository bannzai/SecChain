import Foundation
import SecChainCore
import Testing

@testable import SecChainCLI

/// Authenticator double that records the reason of every prompt.
final class RecordingOwnerAuthenticator: OwnerAuthenticating, @unchecked Sendable {
    /// Guards `recordedReasons`, which a store may append to from another task.
    private let lock = NSLock()
    /// Every reason passed to `authenticate`, oldest first.
    private var recordedReasons: [String] = []

    /// The reasons of the prompts so far, oldest first.
    var reasons: [String] {
        lock.withLock { recordedReasons }
    }

    func authenticate(reason: String) async throws -> OwnerAuthentication {
        lock.withLock {
            recordedReasons.append(reason)
        }
        return OwnerAuthentication(context: nil)
    }
}

/// The arguments of `secchain set` that decide where the value comes from.
@Suite
struct SetCommandTests {
    /// An obviously fake value, never a real credential.
    let dummyValue = "dummy-value-for-test"
    /// A second fake value, to tell which variable was read.
    let otherDummyValue = "other-dummy-value-for-test"
    /// The secret every case stores.
    let secretName = SecretName(rawName: "API_KEY")!

    @Test
    func withoutAVariableTheOptionReadsTheOneNamedLikeTheSecret() throws {
        let command = try SetCommand.parse(["API_KEY", "--from-variable"])
        #expect(command.valueVariableName(secretName: secretName) == "API_KEY")
        #expect(
            try command.secretValue(secretName: secretName, environment: ["API_KEY": dummyValue, "OTHER_KEY": otherDummyValue])
                == SecretValue(exposingString: dummyValue)
        )
    }

    @Test
    func aNamedVariableIsReadInsteadOfTheSecretsName() throws {
        let command = try SetCommand.parse(["API_KEY", "--from-variable", "OTHER_KEY"])
        #expect(command.valueVariableName(secretName: secretName) == "OTHER_KEY")
        #expect(
            try command.secretValue(secretName: secretName, environment: ["API_KEY": dummyValue, "OTHER_KEY": otherDummyValue])
                == SecretValue(exposingString: otherDummyValue)
        )
    }

    @Test
    func withoutTheOptionNoVariableIsRead() throws {
        #expect(try SetCommand.parse(["API_KEY"]).valueVariableName(secretName: secretName) == nil)
    }

    /// An option that follows `--from-variable` is never taken for the variable's name.
    @Test(arguments: [
        (["API_KEY", "--from-variable", "--scope", "user", "--env", "prod", "--level", "confirm", "--no-sync"], "API_KEY"),
        (["API_KEY", "--scope", "user", "--from-variable", "OTHER_KEY", "--env", "prod", "--level", "confirm", "--no-sync"], "OTHER_KEY"),
        (["API_KEY", "--scope", "user", "--env", "prod", "--level", "confirm", "--no-sync", "--from-variable"], "API_KEY"),
    ])
    func theOptionGoesWithTheOtherOptionsOfSet(arguments: [String], variableName: String) throws {
        let command = try SetCommand.parse(arguments)
        #expect(command.valueVariableName(secretName: secretName) == variableName)
        #expect(command.scopeOptions.scope == "user")
        #expect(command.environmentOptions.environment == "prod")
        #expect(command.level == .confirm)
        #expect(command.sync == false)
    }

    @Test
    func aMissingVariableIsRefusedByNameWithoutAValue() throws {
        let command = try SetCommand.parse(["API_KEY", "--from-variable"])
        let error = try #require(throws: (any Error).self) {
            try command.secretValue(secretName: secretName, environment: ["OTHER_KEY": otherDummyValue])
        }
        let message = SetCommand.message(for: error)
        #expect(message.contains("API_KEY is not set in the environment of this command"))
        #expect(!message.contains(otherDummyValue))
    }

    /// What is typed where the variable's name goes may be the value itself, so it is refused before
    /// the command runs, and not repeated.
    @Test
    func aVariableNameThatIsNoVariableNameIsRefusedWithoutRepeatingIt() throws {
        let error = try #require(throws: (any Error).self) {
            try SetCommand.parse(["API_KEY", "--from-variable", dummyValue])
        }
        let message = SetCommand.message(for: error)
        #expect(message.contains("not an environment variable name"))
        #expect(!message.contains(dummyValue))
    }

    /// A value from a variable replaces a stored value through the same `SecretStore.set` as a typed
    /// one, so the replacement asks for authentication even at the standard level.
    @Test
    func aValueFromAVariableReplacesAStoredOneOnlyAfterAnAuthentication() async throws {
        let keychain = InMemorySecretKeychain()
        let authenticator = RecordingOwnerAuthenticator()
        let store = SecretStore(keychain: keychain, ownerAuthenticator: authenticator)
        let scope = SecretScope.repository(RepositoryIdentity(value: "github.com/example/a"))
        let command = try SetCommand.parse(["API_KEY", "--from-variable"])
        let environment = ["API_KEY": dummyValue]

        try await store.set(name: secretName, value: try command.secretValue(secretName: secretName, environment: environment), scope: scope, environment: nil, protectionLevel: command.level, isSynchronized: command.sync)
        #expect(authenticator.reasons.isEmpty)
        try await store.set(name: secretName, value: try command.secretValue(secretName: secretName, environment: environment), scope: scope, environment: nil, protectionLevel: command.level, isSynchronized: command.sync)
        #expect(authenticator.reasons == ["update API_KEY"])
        #expect(try await store.values(names: nil, scopes: [scope], environment: nil, authenticationReason: "run")[secretName] == SecretValue(exposingString: dummyValue))
    }
}
