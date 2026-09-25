import ArgumentParser
import Foundation
import SecChainCore

/// `secchain list`: the names of the secrets `run` passes to the repository, or of one scope.
/// Values are never printed.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the secret names 'secchain run' passes to this repository: its own and those of the shared scopes allowed for it. Values are never shown."
    )

    @Flag(name: .shortAndLong, help: "Also show the protection level, synchronization, the scope each secret comes from, and declared secrets that have no value yet.")
    var long = false

    @Flag(help: "List the repositories that have secrets on this Mac instead.")
    var repositories = false

    @Flag(help: "List the shared scopes and the '@allow' patterns of ~/.secchain that pass each of them to repositories instead.")
    var scopes = false

    @OptionGroup
    var scopeOptions: ScopeOptions

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    func run() throws {
        if repositories {
            for repositoryIdentity in try SecretStore.system.repositoryIdentities() {
                print(repositoryIdentity.value)
            }
            return
        }
        if scopes {
            try listSharedScopes()
            return
        }
        if let sharedScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository) {
            try listScope(
                scope: .shared(sharedScope),
                declaredSecretNames: try readUserDefinition().definition.scopeDefinition(scope: sharedScope)?.secretNames ?? [],
                definitionFileName: "~/\(UserDefinitionText.fileName)"
            )
            return
        }
        let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        if scopeOptions.scope == SecretScope.repositoryScopeName {
            try listScope(
                scope: .repository(context.repositoryIdentity),
                declaredSecretNames: context.definition?.secretNames ?? [],
                definitionFileName: SecretDefinitionText.fileName
            )
            return
        }
        try listPassedScopes(context: context)
    }

    /// The secrets of one scope. `declaredSecretNames` are the names its definition file declares,
    /// the long form reports the ones without a value.
    func listScope(scope: SecretScope, declaredSecretNames: [SecretName], definitionFileName: String) throws {
        let storedSecrets = try SecretStore.system.storedSecrets(scope: scope)
        guard long else {
            for storedSecret in storedSecrets {
                print(storedSecret.name.value)
            }
            return
        }
        print("# \(scope.description)")
        for storedSecret in storedSecrets {
            print("\(storedSecret.name.value)\t\(storedSecret.protectionLevel.rawValue)\t\(storedSecret.isSynchronized ? "synchronized" : "this-mac-only")")
        }
        for declaredSecretName in declaredSecretNames where !storedSecrets.contains(where: { $0.name == declaredSecretName }) {
            print("\(declaredSecretName.value)\tno value stored (declared in \(definitionFileName))")
        }
    }

    /// What `run` passes to the repository. The long form names the scope each secret is taken
    /// from and the other passed scopes that hold the same name, which that secret overrides.
    func listPassedScopes(context: CommandContext) throws {
        let passedScopes = context.userDefinition.passedScopes(repositoryIdentity: context.repositoryIdentity)
        let storedSecrets = try SecretStore.system.storedSecrets(scopes: passedScopes)
        guard long else {
            for storedSecret in storedSecrets {
                print(storedSecret.name.value)
            }
            return
        }
        let storedSecretNamesByScope = try passedScopes.map { scope in
            (scope: scope, secretNames: Set(try SecretStore.system.storedSecrets(scope: scope).map(\.name)))
        }
        print("# \(context.repositoryIdentity.value) (\(passedScopes.map(\.name).joined(separator: ", ")))")
        for storedSecret in storedSecrets {
            let overriddenScopeNames = storedSecretNamesByScope
                .filter { $0.scope != storedSecret.scope && $0.secretNames.contains(storedSecret.name) }
                .map(\.scope.name)
            print(
                "\(storedSecret.name.value)\t\(storedSecret.protectionLevel.rawValue)\t\(storedSecret.isSynchronized ? "synchronized" : "this-mac-only")\t\(storedSecret.scope.name)"
                    + (overriddenScopeNames.isEmpty ? "" : "\t(also in \(overriddenScopeNames.joined(separator: ", ")))")
            )
        }
        if let definition = context.definition {
            for missingSecretName in SecretDefinitionText.missingSecretNames(
                definition: definition,
                storedSecretNames: Set(storedSecrets.map(\.name))
            ) {
                print("\(missingSecretName.value)\tno value stored (declared in .secchain)")
            }
        }
    }

    /// Every shared scope (`UserDefinition.sharedScopes`) with the patterns that pass it to
    /// repositories.
    func listSharedScopes() throws {
        let userDefinition = try readUserDefinition().definition
        for sharedScope in userDefinition.sharedScopes(storedScopes: try SecretStore.system.scopes().compactMap(\.sharedScope)) {
            let allowPatterns = userDefinition.scopeDefinition(scope: sharedScope)?.allowPatterns ?? []
            print("\(sharedScope.name)\t\(allowPatterns.isEmpty ? "(passed to no repository)" : allowPatterns.joined(separator: " "))")
        }
    }
}
