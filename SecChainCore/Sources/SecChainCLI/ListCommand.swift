import ArgumentParser
import Foundation
import SecChainCore

/// `secchain list`: the names of the secrets `run` passes to the repository, or of one scope.
/// Values are never printed.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the secret names 'secchain run' passes to this repository: its own and those of the shared scopes allowed for it. Values are never shown.",
        discussion: """
            With --env, the names 'secchain run --env <environment>' passes. Without it, where a \
            passed scope has environments, the names of every environment; the long form then has a \
            line for each secret and environment.
            """
    )

    @Flag(name: .shortAndLong, help: "Also show the protection level, synchronization, the environment ('-' for none), the scope each secret comes from, and declared secrets that have no value yet.")
    var long = false

    @Flag(help: "List the repositories that have secrets on this Mac instead.")
    var repositories = false

    @Flag(help: "List the shared scopes and the '@allow' patterns of ~/.secchain that pass each of them to repositories instead.")
    var scopes = false

    @Flag(help: "List the environments of each scope passed to this repository (or of the scope of --scope), and how many of its secrets have no environment, instead.")
    var envs = false

    @OptionGroup
    var scopeOptions: ScopeOptions

    @OptionGroup
    var environmentOptions: EnvironmentOptions

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
        let environment = try environmentOptions.validatedEnvironment()
        if let sharedScope = try scopeOptions.sharedScope(repositoryOption: repositoryOptions.repository) {
            if envs {
                try listEnvironments(scopes: [.shared(sharedScope)])
                return
            }
            try listScope(
                scope: .shared(sharedScope),
                environment: environment,
                declaredSecretNames: try readUserDefinition().definition.scopeDefinition(scope: sharedScope)?.secretNames ?? [],
                definitionFileName: "~/\(UserDefinitionText.fileName)"
            )
            return
        }
        let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        if scopeOptions.scope == SecretScope.repositoryScopeName {
            if envs {
                try listEnvironments(scopes: [.repository(context.repositoryIdentity)])
                return
            }
            try listScope(
                scope: .repository(context.repositoryIdentity),
                environment: environment,
                declaredSecretNames: context.definition?.secretNames ?? [],
                definitionFileName: SecretDefinitionText.fileName
            )
            return
        }
        let passedScopes = context.userDefinition.passedScopes(repositoryIdentity: context.repositoryIdentity)
        if envs {
            try listEnvironments(scopes: passedScopes)
            return
        }
        try listPassedScopes(context: context, passedScopes: passedScopes, environment: environment)
    }

    /// The secrets of one scope, in `environment` when one is named and in every environment
    /// otherwise. `declaredSecretNames` are the names its definition file declares, the long form
    /// reports the ones without a value.
    func listScope(scope: SecretScope, environment: SecretEnvironment?, declaredSecretNames: [SecretName], definitionFileName: String) throws {
        let storedSecrets = try environment.map { try SecretStore.system.storedSecrets(scope: scope, environment: $0) }
            ?? SecretStore.system.storedSecrets(scope: scope)
        guard long else {
            printNames(storedSecrets: storedSecrets)
            return
        }
        print("# \(scope.locationDescription(environment: environment))")
        for storedSecret in storedSecrets {
            print("\(storedSecret.name.value)\t\(storedSecret.protectionLevel.rawValue)\t\(storedSecret.isSynchronized ? "synchronized" : "this-mac-only")\t\(environmentColumn(storedSecret: storedSecret))")
        }
        for declaredSecretName in declaredSecretNames where !storedSecrets.contains(where: { $0.name == declaredSecretName }) {
            print("\(declaredSecretName.value)\tno value stored (declared in \(definitionFileName))")
        }
    }

    /// What `run` passes to the repository. The long form names the scope each secret is taken
    /// from and the other passed scopes that offer the same name, which that secret overrides.
    ///
    /// Without `environment`, a passed scope that has environments leaves `run` refusing to start,
    /// so there is no one set of secrets to show: the names of every environment are listed
    /// instead, and the long form has a line for each secret and environment.
    func listPassedScopes(context: CommandContext, passedScopes: [SecretScope], environment: SecretEnvironment?) throws {
        let storedSecretsOfPassedScopes = try passedScopes.flatMap { try SecretStore.system.storedSecrets(scope: $0) }
        let offeredSecrets: [StoredSecret]
        do {
            offeredSecrets = try RunPlan.offeredSecrets(storedSecrets: storedSecretsOfPassedScopes, passedScopes: passedScopes, environment: environment)
        } catch RunPlanError.environmentRequired {
            try listEveryEnvironment(context: context, passedScopes: passedScopes, storedSecrets: storedSecretsOfPassedScopes)
            return
        }
        let passedSecrets = try RunPlan.passedSecrets(storedSecrets: storedSecretsOfPassedScopes, passedScopes: passedScopes, environment: environment)
        guard long else {
            printNames(storedSecrets: passedSecrets)
            return
        }
        print("# \(context.repositoryIdentity.value) (\(passedScopes.map(\.name).joined(separator: ", ")))\(environment.map { ", environment \($0.value)" } ?? "")")
        for storedSecret in passedSecrets {
            let overriddenScopeNames = offeredSecrets
                .filter { $0.scope != storedSecret.scope && $0.name == storedSecret.name }
                .map(\.scope.name)
            print(
                "\(storedSecret.name.value)\t\(storedSecret.protectionLevel.rawValue)\t\(storedSecret.isSynchronized ? "synchronized" : "this-mac-only")\t\(environmentColumn(storedSecret: storedSecret))\t\(storedSecret.scope.name)"
                    + (overriddenScopeNames.isEmpty ? "" : "\t(also in \(overriddenScopeNames.joined(separator: ", ")))")
            )
        }
        if let definition = context.definition {
            for missingSecretName in SecretDefinitionText.missingSecretNames(
                definition: definition,
                storedSecretNames: Set(passedSecrets.map(\.name))
            ) {
                print("\(missingSecretName.value)\tno value stored (declared in .secchain)")
            }
        }
    }

    /// `listPassedScopes` without an environment while a passed scope has environments: every
    /// secret of the passed scopes, in the order of precedence of their scopes.
    func listEveryEnvironment(context: CommandContext, passedScopes: [SecretScope], storedSecrets: [StoredSecret]) throws {
        guard long else {
            printNames(storedSecrets: storedSecrets)
            return
        }
        print("# \(context.repositoryIdentity.value) (\(passedScopes.map(\.name).joined(separator: ", "))), every environment; 'secchain list --env <environment>' shows what 'secchain run --env <environment>' passes")
        for storedSecret in storedSecrets.sorted(by: { $0.name < $1.name }) {
            print("\(storedSecret.name.value)\t\(storedSecret.protectionLevel.rawValue)\t\(storedSecret.isSynchronized ? "synchronized" : "this-mac-only")\t\(environmentColumn(storedSecret: storedSecret))\t\(storedSecret.scope.name)")
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

    /// For each of `scopes`: its name, its environments ('-' for none), and how many of its secrets
    /// have no environment, which `run` does not pass once the scope has environments.
    func listEnvironments(scopes: [SecretScope]) throws {
        for scope in scopes {
            let environments = try SecretStore.system.environments(scope: scope)
            let secretsWithoutEnvironmentCount = try SecretStore.system.storedSecrets(scope: scope, environment: nil).count
            print("\(scope.name)\t\(environments.isEmpty ? "-" : environments.map(\.value).joined(separator: " "))\t\(secretsWithoutEnvironmentCount) without an environment")
        }
    }

    /// The names of `storedSecrets`, each once and sorted: a name that several environments hold is
    /// one environment variable.
    func printNames(storedSecrets: [StoredSecret]) {
        for secretName in Set(storedSecrets.map(\.name)).sorted() {
            print(secretName.value)
        }
    }

    /// The environment column of the long form: the environment, `-` for a secret without one.
    func environmentColumn(storedSecret: StoredSecret) -> String {
        storedSecret.environment?.value ?? "-"
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
