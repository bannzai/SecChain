import Foundation
import LocalAuthentication
import Security
import Testing

@testable import SecChainCore

@Suite
struct SecretValueTests {
    let secretText = "dummy-value-for-test"

    @Test
    func noTextualRepresentationContainsTheValue() {
        let value = SecretValue(exposingString: secretText)
        var dumped = ""
        dump(value, to: &dumped)
        for representation in [String(describing: value), String(reflecting: value), "\(value)", dumped, "\([value])", "\(["k": value])"] {
            #expect(!representation.contains(secretText))
        }
    }

    @Test
    func theValueIsOnlyReachableThroughTheExposingMembers() {
        let value = SecretValue(exposingString: secretText)
        #expect(value.exposedString == secretText)
        #expect(value.exposedData == Data(secretText.utf8))
    }
}

@Suite
struct SecretStoreErrorTests {
    @Test
    func keychainStatusesBecomeActionableErrors() {
        func mapped(_ status: OSStatus) -> SecretStoreError {
            // The label is omitted because the helper only shortens the table below.
            SecretStoreErrorMapping.error(status: status, operation: "read", name: "API_KEY", repository: "github.com/example/a")
        }
        #expect(mapped(errSecItemNotFound) == .secretNotFound(name: "API_KEY", repository: "github.com/example/a"))
        #expect(mapped(errSecDuplicateItem) == .duplicateSecret(name: "API_KEY", repository: "github.com/example/a"))
        #expect(mapped(errSecMissingEntitlement) == .missingEntitlement)
        #expect(mapped(errSecAuthFailed) == .authenticationFailed)
        #expect(mapped(errSecUserCanceled) == .authenticationCancelled)
        #expect(mapped(errSecInteractionNotAllowed) == .authenticationNotPossible)
        #expect(mapped(errSecNotAvailable) == .keychainUnavailable)
        guard case .keychainFailure(let operation, let status, let message) = mapped(errSecParam) else {
            Issue.record("errSecParam should map to keychainFailure")
            return
        }
        #expect(operation == "read")
        #expect(status == errSecParam)
        #expect(!message.isEmpty)
    }

    @Test
    func localAuthenticationCodesBecomeActionableErrors() {
        func mapped(_ code: LAError.Code) -> SecretStoreError {
            // The label is omitted because the helper only shortens the table below.
            SecretStoreErrorMapping.error(localAuthenticationErrorCode: code.rawValue, message: "system message")
        }
        #expect(mapped(.authenticationFailed) == .authenticationFailed)
        #expect(mapped(.userCancel) == .authenticationCancelled)
        #expect(mapped(.appCancel) == .authenticationCancelled)
        #expect(mapped(.systemCancel) == .authenticationCancelled)
        #expect(mapped(.notInteractive) == .authenticationNotPossible)
        #expect(mapped(.passcodeNotSet) == .authenticationUnavailable(reason: "system message"))
    }

    @Test
    func theMissingEntitlementMessagePointsToCodeSigning() {
        #expect(SecretStoreError.missingEntitlement.description.contains("signed"))
        #expect(SecretStoreError.missingEntitlement.description.contains("secchain doctor"))
    }

    @Test
    func protectionLevelsAreOrderedByStrictness() {
        #expect(ProtectionLevel.standard < .confirm)
        #expect(ProtectionLevel.confirm < .deviceBound)
        #expect(ProtectionLevel(rawValue: "device-bound") == .deviceBound)
    }
}
