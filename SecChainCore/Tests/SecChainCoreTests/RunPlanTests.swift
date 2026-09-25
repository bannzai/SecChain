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
    /// it hold `secretNamesOfScopesNotPassed`. Without an environment by default, the way a
    /// repository without environments runs.
    func plannedSecretNames(
        storedSecretNames: [SecretName],
        definition: SecretDefinition?,
        onlyNames: [SecretName],
        environment: SecretEnvironment? = nil,
        secretNamesOfScopesNotPassed: [SharedScope: Set<SecretName>] = [:]
    ) throws -> [SecretName] {
        try RunPlan.secretNames(
            storedSecretNames: storedSecretNames,
            definition: definition,
            onlyNames: onlyNames,
            repositoryIdentity: repositoryIdentity,
            environment: environment,
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
        #expect(throws: RunPlanError.declaredSecretsWithoutValue(names: ["C"], repository: repositoryIdentity.value, environment: nil, sharedScopeNamesBySecretName: [:])) {
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
            environment: nil,
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
            environment: nil,
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
            StoredSecret(scope: scope, name: try #require(SecretName(rawName: rawName)), environment: nil, protectionLevel: .confirm, isSynchronized: true, modificationDate: nil)
        }
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: passedScopes,
                environment: nil,
                requestedSecrets: [try storedSecret(scope: .repository(repositoryIdentity), rawName: "A")]
            ) == "run npm with secrets of github.com/example/a"
        )
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: passedScopes,
                environment: nil,
                requestedSecrets: [try storedSecret(scope: .shared(.user), rawName: "A"), try storedSecret(scope: youtube, rawName: "B")]
            ) == "run npm with secrets of github.com/example/a and of the youtube, user scopes"
        )
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: passedScopes,
                environment: nil,
                requestedSecrets: [try storedSecret(scope: .shared(.user), rawName: "A")]
            ) == "run npm with secrets of github.com/example/a and of the user scope"
        )
    }

    // MARK: - Environments

    /// A secret of `scope` in `environment` (`nil` for none), standard and synchronized.
    func storedSecret(scope: SecretScope, rawName: String, environment rawEnvironment: String?) throws -> StoredSecret {
        StoredSecret(
            scope: scope,
            name: try #require(SecretName(rawName: rawName)),
            environment: try rawEnvironment.map { try #require(SecretEnvironment(rawName: $0)) },
            protectionLevel: .standard,
            isSynchronized: true,
            modificationDate: nil
        )
    }

    /// `RunPlan.passedSecrets` as `NAME=scope/environment` lines, `-` for no environment.
    func passedSecretLines(storedSecrets: [StoredSecret], passedScopes: [SecretScope], environment rawEnvironment: String?) throws -> [String] {
        try RunPlan.passedSecrets(
            storedSecrets: storedSecrets,
            passedScopes: passedScopes,
            environment: try rawEnvironment.map { try #require(SecretEnvironment(rawName: $0)) }
        )
        .map { "\($0.name.value)=\($0.scope.name)/\($0.environment?.value ?? "-")" }
    }

    @Test
    func withoutEnvironmentsEveryScopeGivesItsSecretsWithOrWithoutAnEnvironmentNamed() throws {
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity), .shared(.user)]
        let storedSecrets = [
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "A", environment: nil),
            try storedSecret(scope: .shared(.user), rawName: "B", environment: nil),
        ]
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: nil) == ["A=repository/-", "B=user/-"])
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "prod") == ["A=repository/-", "B=user/-"])
    }

    @Test
    func withEnvironmentsOnlyTheNamedOneIsGivenAndNothingFallsBack() throws {
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity)]
        let storedSecrets = [
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "A", environment: "local"),
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "A", environment: "prod"),
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "B", environment: "local"),
            // Left without an environment: no environment gives it.
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "C", environment: nil),
        ]
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "local") == ["A=repository/local", "B=repository/local"])
        // B has no prod value, and neither B of local nor C without an environment stands in for it.
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "prod") == ["A=repository/prod"])
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "staging").isEmpty)
    }

    @Test
    func aUserScopeWithoutEnvironmentsIsGivenInEveryEnvironmentOfTheRepository() throws {
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity), .shared(.user)]
        let storedSecrets = [
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "A", environment: "prod"),
            try storedSecret(scope: .shared(.user), rawName: "OPENAI_API_KEY", environment: nil),
        ]
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "prod") == ["A=repository/prod", "OPENAI_API_KEY=user/-"])
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "local") == ["OPENAI_API_KEY=user/-"])
    }

    @Test
    func aUserScopeWithEnvironmentsGivesItsEnvironmentToARepositoryWithout() throws {
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity), .shared(.user)]
        let storedSecrets = [
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "A", environment: nil),
            try storedSecret(scope: .shared(.user), rawName: "OPENAI_API_KEY", environment: "prod"),
            try storedSecret(scope: .shared(.user), rawName: "OPENAI_API_KEY", environment: "local"),
        ]
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "prod") == ["A=repository/-", "OPENAI_API_KEY=user/prod"])
        #expect(throws: RunPlanError.self) {
            try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: nil)
        }
    }

    /// The repository comes first, then the custom scopes, then the user scope, in an environment
    /// as without one; a scope without environments takes part in that order as well.
    @Test
    func aNameInSeveralScopesComesFromTheFirstWithinTheEnvironment() throws {
        let youtube = SecretScope.shared(.custom(try #require(CustomScopeName(rawName: "youtube"))))
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity), youtube, .shared(.user)]
        let storedSecrets = [
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "SHARED", environment: "local"),
            try storedSecret(scope: youtube, rawName: "SHARED", environment: nil),
            try storedSecret(scope: youtube, rawName: "FROM_YOUTUBE", environment: nil),
            try storedSecret(scope: .shared(.user), rawName: "SHARED", environment: "prod"),
            try storedSecret(scope: .shared(.user), rawName: "SHARED", environment: "local"),
            try storedSecret(scope: .shared(.user), rawName: "FROM_YOUTUBE", environment: "prod"),
        ]
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "local") == ["FROM_YOUTUBE=youtube/-", "SHARED=repository/local"])
        #expect(try passedSecretLines(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: "prod") == ["FROM_YOUTUBE=youtube/-", "SHARED=youtube/-"])
    }

    @Test
    func withoutAnEnvironmentAScopeWithEnvironmentsStopsTheRunAndSaysHowToGoOn() throws {
        let passedScopes: [SecretScope] = [.repository(repositoryIdentity), .shared(.user)]
        let storedSecrets = [
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "A", environment: "local"),
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "B", environment: "prod"),
            try storedSecret(scope: .repository(repositoryIdentity), rawName: "LEFT_OVER", environment: nil),
            try storedSecret(scope: .shared(.user), rawName: "OPENAI_API_KEY", environment: nil),
        ]
        let expectedError = RunPlanError.environmentRequired(
            scopesWithEnvironments: [.repository(repositoryIdentity)],
            environments: ["local", "prod"],
            secretNamesWithoutEnvironmentByScope: [.repository(repositoryIdentity): ["LEFT_OVER"]]
        )
        #expect(throws: expectedError) {
            try RunPlan.passedSecrets(storedSecrets: storedSecrets, passedScopes: passedScopes, environment: nil)
        }
        #expect(
            expectedError.description.components(separatedBy: "\n") == [
                "github.com/example/a has the environments local, prod, so name the one to run with: secchain run --env <environment> -- <command>",
                "These secrets of github.com/example/a have no environment, and 'secchain run' does not pass them: LEFT_OVER.",
                "To move all of them to one environment: secchain env migrate local (any name works; 'local' is an example).",
                "To move them one at a time: secchain env migrate <environment> <NAME>",
                "Where a value differs between environments, move it, then store the value of each other environment: secchain set <NAME> --env <environment>",
            ]
        )
    }

    @Test
    func aDeclaredSecretWithoutAValueInTheEnvironmentNamesTheEnvironment() throws {
        let expectedError = RunPlanError.declaredSecretsWithoutValue(names: ["C"], repository: repositoryIdentity.value, environment: "prod", sharedScopeNamesBySecretName: [:])
        #expect(throws: expectedError) {
            try plannedSecretNames(
                storedSecretNames: try names(["A"]),
                definition: try SecretDefinitionText.parse(text: "A\nC"),
                onlyNames: [],
                environment: SecretEnvironment(rawName: "prod")
            )
        }
        #expect(expectedError.description == ".secchain declares secrets that have no stored value in the environment prod: C. Store each with 'secchain set <NAME> --env prod'.")
    }

    @Test
    func thePromptNamesTheEnvironment() throws {
        #expect(
            RunPlan.authenticationReason(
                executable: "npm",
                repositoryIdentity: repositoryIdentity,
                passedScopes: [.repository(repositoryIdentity), .shared(.user)],
                environment: SecretEnvironment(rawName: "prod"),
                requestedSecrets: [try storedSecret(scope: .shared(.user), rawName: "A", environment: nil)]
            ) == "run npm with secrets of github.com/example/a and of the user scope in the environment prod"
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
