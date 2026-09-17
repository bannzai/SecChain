import ArgumentParser
import Foundation
import SecChainCore

/// `secchain list`: the names of the repository's secrets. Values are never printed.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the secret names of this repository. Values are never shown."
    )

    @Flag(name: .shortAndLong, help: "Also show the protection level, synchronization, and declared secrets that have no value yet.")
    var long = false

    @Flag(help: "List the repositories that have secrets on this Mac instead.")
    var repositories = false

    @OptionGroup
    var repositoryOptions: RepositoryOptions

    func run() throws {
        if repositories {
            for repositoryIdentity in try SecretStore.system.repositoryIdentities() {
                print(repositoryIdentity.value)
            }
            return
        }
        let context = try CommandContext.resolve(repositoryOption: repositoryOptions.repository)
        let storedSecrets = try SecretStore.system.storedSecrets(repositoryIdentity: context.repositoryIdentity)
        guard long else {
            for storedSecret in storedSecrets {
                print(storedSecret.name.value)
            }
            return
        }
        print("# \(context.repositoryIdentity.value)")
        for storedSecret in storedSecrets {
            print("\(storedSecret.name.value)\t\(storedSecret.protectionLevel.rawValue)\t\(storedSecret.isSynchronized ? "synchronized" : "this-mac-only")")
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
}
