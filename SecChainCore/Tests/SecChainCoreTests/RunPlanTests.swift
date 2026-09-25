import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RunPlanTests {
    let repositoryIdentity = RepositoryIdentity(value: "github.com/example/a")

    func names(_ rawNames: [String]) throws -> [SecretName] {
        // The label is omitted because every call site passes a literal list.
        try rawNames.map { try #require(SecretName(rawName: $0)) }
    }

    /// `RunPlan.secretNames` for the test repository, where the shared scopes that are not passed to
    /// it hold `secretNamesOfScopesNotPassed`.
    func plannedSecretNames(
        storedSecretNames: [SecretName],
        definition: SecretDefinition?,
        onlyNames: [SecretName],
        secretNamesOfScopesNotPassed: [SharedScope: Set<SecretName>] = [:]
    ) throws -> [SecretName] {
        try RunPlan.secretNames(
            storedSecretNames: storedSecretNames,
            definition: definition,
            onlyNames: onlyNames,
            repositoryIdentity: repositoryIdentity,
            secretNamesOfScopesNotPassed: { secretNamesOfScopesNotPassed }
        )
    }

    @Test
    func withoutADefinitionEveryStoredSecretIsUsed() throws {
        #expect(
            try plannedSecretNames(storedSecretNames: try names(["A", "B"]), definition: nil, onlyNames: [])
                == (try names(["A", "B"]))
        )
    }

    @Test
    func onlyNamesRestrictTheSelection() throws {
        #expect(
            try plannedSecretNames(
                storedSecretNames: try names(["A", "B"]),
                definition: try SecretDefinitionText.parse(text: "A\nB\nC"),
                onlyNames: try names(["B"])
            ) == (try names(["B"]))
        )
    }

    @Test
    func aDeclaredSecretWithoutAValueStopsTheRun() throws {
        #expect(throws: RunPlanError.declaredSecretsWithoutValue(names: ["C"], repository: repositoryIdentity.value, sharedScopeNamesBySecretName: [:])) {
            try plannedSecretNames(
                storedSecretNames: try names(["A", "B"]),
                definition: try SecretDefinitionText.parse(text: "A\nC"),
                onlyNames: []
            )
        }
    }

    @Test
    func aDeclaredSecretThatOnlyAScopeNotAllowedHoldsNamesThatScope() throws {
        let youtube = SharedScope.custom(try #require(CustomScopeName(rawName: "youtube")))
        let video = SharedScope.custom(try #require(CustomScopeName(rawName: "video")))
        let expectedError = RunPlanError.declaredSecretsWithoutValue(
            names: ["A", "YOUTUBE_API_KEY", "OPENAI_API_KEY"],
            repository: repositoryIdentity.value,
            sharedScopeNamesBySecretName: ["YOUTUBE_API_KEY": ["video", "youtube"], "OPENAI_API_KEY": ["user"]]
        )
        #expect(throws: expectedError) {
            try plannedSecretNames(
                storedSecretNames: [],
                definition: try SecretDefinitionText.parse(text: "A\nYOUTUBE_API_KEY\nOPENAI_API_KEY"),
                onlyNames: [],
                secretNamesOfScopesNotPassed: [
                    youtube: Set(try names(["YOUTUBE_API_KEY"])),
                    video: Set(try names(["YOUTUBE_API_KEY"])),
                    .user: Set(try names(["OPENAI_API_KEY"])),
                ]
            )
        }
        // The fix is named: storing the one no scope has, allowing a scope for the others.
        #expect(
            expectedError.description.components(separatedBy: "\n") == [
                ".secchain declares secrets that have no stored value: A. Store each with 'secchain set <NAME>'.",
                ".secchain declares YOUTUBE_API_KEY, which is in scopes video, youtube, none of them allowed for github.com/example/a. Allow one with 'secchain scope allow <scope> github.com/example/a'.",
                ".secchain declares OPENAI_API_KEY, which is in scope user, not allowed for github.com/example/a. Allow it with 'secchain scope allow user github.com/example/a'.",
            ]
        )
    }

    @Test
    func theScopesThatAreNotPassedAreOnlyLookedAtWhenADeclaredSecretHasNoValue() throws {
        _ = try RunPlan.secretNames(
            storedSecretNames: try names(["A"]),
            definition: try SecretDefinitionText.parse(text: "A"),
            onlyNames: [],
            repositoryIdentity: repositoryIdentity,
            secretNamesOfScopesNotPassed: {
                Issue.record("listed every scope although nothing was missing")
                return [:]
            }
        )
    }

    @Test
    func thePromptNamesTheSharedScopesOfTheRequestedSecretsInTheOrderTheyArePassed() throws {
        let youtube = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        let video = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "video"))))
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity), youtube, video, .shared(.user)]
        func storedSecret(scope: SecretScope, rawName: String) throws -> StoredSecret {
            StoredSecret(scope: scope, name: try #require(SecretName(rawName: rawName)), protectionLevel: .confirm, isSynchronized: true, modificationDate: nil)
        }
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: passedScopes,
                requestedSecrets: [try storedSecret(scope: .repository(repositoryIdentity), rawName: "A")]
            ) == "run npm with secrets of github.com/example/a"
        )
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: passedScopes,
                requestedSecrets: [try storedSecret(scope: .shared(.user), rawName: "A"), try storedSecret(scope: youtube, rawName: "B")]
            ) == "run npm with secrets of github.com/example/a and of the youtube, user scopes"
        )
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: passedScopes,
                requestedSecrets: [try storedSecret(scope: .shared(.user), rawName: "A")]
            ) == "run npm with secrets of github.com/example/a and of the user scope"
        )
    }

    @Test
    func secretsAreAddedToTheInheritedEnvironmentAndOverrideIt() throws {
        let environment = try RunPlan.childEnvironment(
            inheritedEnvironment: ["PATH": "/usr/bin", "A": "inherited"],
            values: [
                try #require(SecretName(rawName: "A")): SecretValue(exposingString: "dummy-value-for-test"),
                try #require(SecretName(rawName: "B")): SecretValue(exposingString: "other-dummy-value-for-test"),
            ]
        )
        #expect(environment == ["PATH": "/usr/bin", "A": "dummy-value-for-test", "B": "other-dummy-value-for-test"])
    }

    @Test
    func aNonTextValueIsRejectedWithoutEchoingIt() throws {
        #expect(throws: RunPlanError.valueIsNotText(name: "A")) {
            try RunPlan.childEnvironment(
                inheritedEnvironment: [:],
                values: [try #require(SecretName(rawName: "A")): SecretValue(exposingData: Data([0xFF, 0xFE]))]
            )
        }
    }
}
