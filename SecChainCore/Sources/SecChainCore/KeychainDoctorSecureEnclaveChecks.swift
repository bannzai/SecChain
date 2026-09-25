import CryptoKit
import Foundation
import LocalAuthentication
import Security

extension KeychainDoctor {
    /// Checks what remote approval needs from the Secure Enclave of the approving device (issue #32):
    /// a key that never leaves the device signs an approval that verifies with its public key, and a
    /// key can demand Face ID / Touch ID for every signature. The keys are not stored anywhere.
    public static func runSecureEnclaveChecks() -> [KeychainDoctorCheck] {
        let request = RemoteApprovalRequest.filed(
            repositoryIdentity: RepositoryIdentity(value: "github.com/bannzai/SecChain"),
            secretScopes: Dictionary(uniqueKeysWithValues: ["DUMMY_NAME_FOR_DOCTOR"].compactMap(SecretName.init(rawName:)).map { ($0, SecretScope.repository(RepositoryIdentity(value: "github.com/bannzai/SecChain"))) }),
            commandArguments: ["true"],
            requestingDeviceName: "doctor",
            now: Date(),
            expiryInterval: RemoteApprovalSession.expiryInterval
        )
        var checks = [
            KeychainDoctorCheck(
                name: "Secure Enclave: available",
                status: errSecSuccess,
                passed: SecureEnclave.isAvailable,
                detail: "SecureEnclave.isAvailable = \(SecureEnclave.isAvailable)"
            ),
        ]

        do {
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey()
            try RemoteApproval.verify(
                signature: try RemoteApproval.signature(request: request) { try privateKey.signature(for: $0) },
                request: request,
                publicKey: privateKey.publicKey,
                now: Date()
            )
            checks.append(KeychainDoctorCheck(name: "Secure Enclave: a key signs an approval that verifies with its public key", status: errSecSuccess, passed: true, detail: ""))
        } catch {
            checks.append(KeychainDoctorCheck(name: "Secure Enclave: a key signs an approval that verifies with its public key", status: errSecSuccess, passed: false, detail: "\(error)"))
        }

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            // `.biometryAny` rather than `.biometryCurrentSet` (documents/PROJECT.md, design
            // decision 5): changing the enrolled Face ID or Touch ID must not force the user to
            // pair every Mac again.
            [.privateKeyUsage, .biometryAny],
            &accessControlError
        ) else {
            checks.append(KeychainDoctorCheck(name: "Secure Enclave: create an access control that requires the current biometry", status: errSecParam, passed: false, detail: "\(accessControlError.map { $0.takeRetainedValue() }.map(String.init(describing:)) ?? "nil")"))
            return checks
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        do {
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl, authenticationContext: context)
            checks.append(KeychainDoctorCheck(name: "Secure Enclave: create a key that requires Face ID / Touch ID for every signature", status: errSecSuccess, passed: true, detail: ""))
            do {
                _ = try privateKey.signature(for: RemoteApproval.signedMessage(request: request))
                checks.append(KeychainDoctorCheck(name: "Secure Enclave: that key refuses to sign without Face ID / Touch ID", status: errSecSuccess, passed: false, detail: "a signature was made without authentication"))
            } catch {
                checks.append(KeychainDoctorCheck(name: "Secure Enclave: that key refuses to sign without Face ID / Touch ID", status: errSecSuccess, passed: true, detail: "\(error)"))
            }
        } catch {
            checks.append(KeychainDoctorCheck(name: "Secure Enclave: create a key that requires Face ID / Touch ID for every signature", status: errSecSuccess, passed: false, detail: "\(error)"))
        }

        var biometryError: NSError?
        let biometryContext = LAContext()
        let canEvaluateBiometry = biometryContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError)
        checks.append(
            KeychainDoctorCheck(
                name: "Secure Enclave: Face ID / Touch ID can be evaluated",
                status: errSecSuccess,
                passed: canEvaluateBiometry,
                detail: "biometryType = \(biometryContext.biometryType.rawValue), LAError code \(biometryError?.code ?? 0)"
            )
        )
        return checks
    }
}
