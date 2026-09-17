import Foundation
import Testing

@testable import SecChainCore

@Suite
struct RunPlanTests {
    func names(_ rawNames: [String]) throws -> [SecretName] {
        // The label is omitted because every call site passes a literal list.
        try rawNames.map { try #require(SecretName(rawName: $0)) }
    }

    @Test
    func withoutADefinitionEveryStoredSecretIsUsed() throws {
        #expect(
            try RunPlan.secretNames(storedSecretNames: try names(["A", "B"]), definition: nil, onlyNames: [])
                == (try names(["A", "B"]))
        )
    }

    @Test
    func onlyNamesRestrictTheSelection() throws {
        #expect(
            try RunPlan.secretNames(
                storedSecretNames: try names(["A", "B"]),
                definition: try SecretDefinitionText.parse(text: "A\nB\nC"),
                onlyNames: try names(["B"])
            ) == (try names(["B"]))
        )
    }

    @Test
    func aDeclaredSecretWithoutAValueStopsTheRun() throws {
        #expect(throws: RunPlanError.declaredSecretsWithoutValue(names: ["C"])) {
            try RunPlan.secretNames(
                storedSecretNames: try names(["A", "B"]),
                definition: try SecretDefinitionText.parse(text: "A\nC"),
                onlyNames: []
            )
        }
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
