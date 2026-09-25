import Testing

@testable import SecChainCore

/// The warnings and the advice the command-line tool prints about secrets without an environment.
@Suite
struct EnvironmentGuidanceTests {
    let repositoryScope = SecretScope.repository(RepositoryIdentity(value: "github.com/example/a"))

    /// The environment of a valid literal name.
    func environment(_ rawName: String) throws -> SecretEnvironment {
        // The label is omitted because every call site passes a literal name.
        try #require(SecretEnvironment(rawName: rawName))
    }

    /// The secret names of valid literal names.
    func names(_ rawNames: [String]) throws -> [SecretName] {
        // The label is omitted because every call site passes a literal list.
        try rawNames.map { try #require(SecretName(rawName: $0)) }
    }

    @Test
    func theFirstEnvironmentOfARepositorySaysWhatChangesAndHowToMoveTheRest() throws {
        #expect(
            environmentWarningLines(
                scope: repositoryScope,
                environment: try environment("prod"),
                isFirstEnvironment: true,
                secretNamesWithoutEnvironment: try names(["A", "B"])
            ) == [
                "prod is the first environment of github.com/example/a.",
                "From now on 'secchain run' and 'secchain set' need --env <environment> in github.com/example/a.",
                "These secrets of github.com/example/a have no environment, and 'secchain run' does not pass them: A, B.",
                "To move all of them to one environment: secchain env migrate local (any name works; 'local' is an example).",
                "To move them one at a time: secchain env migrate <environment> <NAME>",
                "Where a value differs between environments, move it, then store the value of each other environment: secchain set <NAME> --env <environment>",
            ]
        )
    }

    /// Every repository the scope is passed to starts needing `--env`, which the user may not have
    /// in mind while acting on the scope alone.
    @Test
    func theFirstEnvironmentOfASharedScopeSaysThatEveryRepositoryItIsPassedToNeedsOne() throws {
        let lines = environmentWarningLines(
            scope: .shared(.user),
            environment: try environment("prod"),
            isFirstEnvironment: true,
            secretNamesWithoutEnvironment: try names(["OPENAI_API_KEY"])
        )
        #expect(lines.contains("From now on 'secchain set --scope user' needs --env <environment>, and so does 'secchain run' in every repository that scope user is passed to."))
        #expect(lines.contains("To move them one at a time: secchain env migrate <environment> <NAME> --scope user"))
    }

    @Test
    func aLaterEnvironmentOnlyListsWhatRemains() throws {
        #expect(
            environmentWarningLines(
                scope: repositoryScope,
                environment: try environment("local"),
                isFirstEnvironment: false,
                secretNamesWithoutEnvironment: try names(["B"])
            ).first == "These secrets of github.com/example/a have no environment, and 'secchain run' does not pass them: B."
        )
    }

    @Test
    func nothingIsSaidWhenNoSecretIsLeftWithoutAnEnvironment() throws {
        #expect(
            environmentWarningLines(scope: repositoryScope, environment: try environment("prod"), isFirstEnvironment: true, secretNamesWithoutEnvironment: []).isEmpty
        )
    }
}
