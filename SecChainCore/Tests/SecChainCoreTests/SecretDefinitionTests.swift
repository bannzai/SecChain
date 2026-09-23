import Foundation
import Testing

@testable import SecChainCore

@Suite
struct SecretDefinitionTests {
    @Test(arguments: ["OPENAI_API_KEY", "_private", "a", "A1_b2"])
    func validSecretNames(name: String) {
        #expect(SecretName(rawName: name)?.value == name)
    }

    @Test(arguments: ["", "1KEY", "MY-KEY", "MY KEY", "KEY=value", "キー", "KEY\n"])
    func invalidSecretNames(name: String) {
        #expect(SecretName(rawName: name) == nil)
    }

    @Test
    func parsesNamesAndComments() throws {
        let definition = try SecretDefinitionText.parse(
            text: """
                # comment

                OPENAI_API_KEY
                  CLOUDFLARE_API_TOKEN
                OPENAI_API_KEY
                """
        )
        #expect(definition.secretNames.map(\.value) == ["OPENAI_API_KEY", "CLOUDFLARE_API_TOKEN"])
    }

    /// A repository's own file must not be able to say which repository it is: an `@allow` of
    /// `~/.secchain` would then pass a shared scope to whatever repository chose the right name.
    @Test
    func theRepositoryDirectiveIsRefusedWithWhereItsUsesMoved() {
        #expect(throws: SecretDefinitionError.repositoryDirectiveRemoved(lineNumber: 2)) {
            try SecretDefinitionText.parse(text: "OPENAI_API_KEY\n@repository github.com/bannzai/anything\n")
        }
        #expect(throws: SecretDefinitionError.repositoryDirectiveRemoved(lineNumber: 1)) {
            try SecretDefinitionText.parse(text: "@repository")
        }
        let message = SecretDefinitionError.repositoryDirectiveRemoved(lineNumber: 2).description
        #expect(message.contains("~/.secchain"))
        #expect(message.contains("@alias"))
        #expect(message.contains("@path"))
    }

    @Test
    func aLineWithAValueIsRejectedWithoutEchoingIt() {
        #expect(throws: SecretDefinitionError.valueNotAllowed(lineNumber: 2)) {
            try SecretDefinitionText.parse(text: "OPENAI_API_KEY\nDATABASE_URL=dummy-value-for-test\n")
        }
        #expect(!SecretDefinitionError.valueNotAllowed(lineNumber: 2).description.contains("dummy-value-for-test"))
    }

    @Test
    func invalidNamesAndDirectivesAreRejected() {
        #expect(throws: SecretDefinitionError.invalidSecretName(lineNumber: 1)) {
            try SecretDefinitionText.parse(text: "MY-KEY")
        }
        #expect(throws: SecretDefinitionError.invalidDirective(lineNumber: 1)) {
            try SecretDefinitionText.parse(text: "@unknown value")
        }
        // The directives of `~/.secchain` do not work here either: a repository cannot pass itself
        // a scope.
        #expect(throws: SecretDefinitionError.invalidDirective(lineNumber: 1)) {
            try SecretDefinitionText.parse(text: "@allow github.com/bannzai/*")
        }
        #expect(throws: SecretDefinitionError.invalidDirective(lineNumber: 1)) {
            try SecretDefinitionText.parse(text: "@scope user")
        }
    }

    @Test
    func addingCreatesTheFileWithAHeaderAndIsIdempotent() throws {
        let name = try #require(SecretName(rawName: "OPENAI_API_KEY"))
        let created = try SecretDefinitionText.adding(secretName: name, text: nil)
        #expect(created.hasPrefix("# SecChain secret definition"))
        #expect(try SecretDefinitionText.parse(text: created).secretNames == [name])
        #expect(try SecretDefinitionText.adding(secretName: name, text: created) == created)
    }

    @Test
    func addingAndRemovingKeepTheUsersCommentsAndOrder() throws {
        let existing = "# mine\nA_KEY\n# about b\nB_KEY"
        let added = try SecretDefinitionText.adding(secretName: try #require(SecretName(rawName: "C_KEY")), text: existing)
        #expect(added == "# mine\nA_KEY\n# about b\nB_KEY\nC_KEY\n")
        let removed = SecretDefinitionText.removing(secretName: try #require(SecretName(rawName: "A_KEY")), text: added)
        #expect(removed == "# mine\n# about b\nB_KEY\nC_KEY\n")
        #expect(SecretDefinitionText.removing(secretName: try #require(SecretName(rawName: "A_KEY")), text: removed) == removed)
    }

    @Test
    func missingSecretNamesAreTheDeclaredOnesWithoutAStoredValue() throws {
        let definition = try SecretDefinitionText.parse(text: "A_KEY\nB_KEY\nC_KEY")
        #expect(
            SecretDefinitionText.missingSecretNames(
                definition: definition,
                storedSecretNames: [try #require(SecretName(rawName: "B_KEY"))]
            ).map(\.value) == ["A_KEY", "C_KEY"]
        )
    }

    @Test
    func fileRoundTripAndAbsentFile() throws {
        let workingTreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("secchain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingTreeRoot, withIntermediateDirectories: true)
        #expect(try SecretDefinitionFile.readText(workingTreeRoot: workingTreeRoot) == nil)
        try SecretDefinitionFile.write(text: "A_KEY\n", workingTreeRoot: workingTreeRoot)
        #expect(try SecretDefinitionFile.readText(workingTreeRoot: workingTreeRoot) == "A_KEY\n")
        #expect(SecretDefinitionFile.url(workingTreeRoot: workingTreeRoot).lastPathComponent == ".secchain")
    }
}
