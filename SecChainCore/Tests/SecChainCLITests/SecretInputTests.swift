import ArgumentParser
import Foundation
import SecChainCore
import Testing

@testable import SecChainCLI

/// Reading a value from an environment variable (`secchain set --from-variable`).
@Suite
struct SecretInputTests {
    /// An obviously fake value, never a real credential.
    let dummyValue = "dummy-value-for-test"

    @Test
    func theValueOfTheVariableIsRead() throws {
        #expect(
            try SecretInput.readFromVariable(variableName: "API_KEY", environment: ["API_KEY": dummyValue, "OTHER": "other-dummy-value-for-test"])
                == SecretValue(exposingString: dummyValue)
        )
    }

    /// A variable that is missing or empty is refused rather than stored as nothing, and the error
    /// names the variable only.
    @Test(arguments: [[:], ["API_KEY": ""]] as [[String: String]])
    func aMissingOrEmptyVariableIsRefusedByName(environment: [String: String]) throws {
        let error = try #require(throws: ValidationError.self) {
            try SecretInput.readFromVariable(variableName: "API_KEY", environment: environment.merging(["OTHER": dummyValue]) { first, _ in first })
        }
        #expect(error.message.hasPrefix("API_KEY is not set in the environment of this command"))
        #expect(!error.message.contains(dummyValue))
    }
}
