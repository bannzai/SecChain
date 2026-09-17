import CryptoKit
import Foundation

/// Why the Mac refuses an approval. Each case is a different forgery or failure, so that callers
/// and tests can tell them apart.
public enum RemoteApprovalVerificationError: Error, Equatable, CustomStringConvertible {
    /// The approval carries no signature, as a record written by anything but the paired iPhone would.
    case missingSignature
    /// The signature is not a P-256 ECDSA signature in raw representation.
    case malformedSignature
    /// The signature was made by a key other than the enrolled one, or over another request.
    case signatureMismatch
    /// The request expired before the approval was verified.
    case expired

    public var description: String {
        switch self {
        case .missingSignature:
            "The approval has no signature."
        case .malformedSignature:
            "The approval's signature is not a P-256 signature."
        case .signatureMismatch:
            "The approval was not signed by the paired device for this request."
        case .expired:
            "The approval request expired."
        }
    }
}

/// Signing and verification of remote approvals, free of CloudKit and of key storage: the private
/// key stays on the iPhone (in the Secure Enclave), the Mac holds the public key enrolled during
/// pairing, and both reach these functions as values.
public enum RemoteApproval {
    /// Separates approval signatures from anything else the same key might sign. The version
    /// changes whenever the layout of the signed message changes, together with
    /// `remoteApprovalSchemaVersion`.
    public static let signedMessagePrefix = Data("SecChain remote approval v1\n".utf8)

    /// SHA-256 over the content the iPhone shows, so that an approval also covers the repository,
    /// the secrets, and the command the user saw. Secret names are sorted because the order in
    /// which a command lists them does not change what is approved.
    public static func contentDigest(request: RemoteApprovalRequest) -> Data {
        Data(SHA256.hash(data: lengthPrefixedConcatenation(fields: [
            Data(request.repositoryIdentity.value.utf8),
            lengthPrefixedConcatenation(fields: request.secretNames.sorted().map { Data($0.value.utf8) }),
            lengthPrefixedConcatenation(fields: request.commandArguments.map { Data($0.utf8) }),
            Data(request.requestingDeviceName.utf8),
        ])))
    }

    /// Bytes that the iPhone signs and the Mac verifies. The expiry is signed in whole seconds
    /// because CloudKit stores dates with millisecond precision, and both sides must produce the
    /// same bytes from their own copy of the request.
    public static func signedMessage(request: RemoteApprovalRequest) -> Data {
        ([
            signedMessagePrefix,
            withUnsafeBytes(of: request.requestIdentifier.uuid) { Data($0) },
            lengthPrefixed(field: request.nonce),
            withUnsafeBytes(of: Int64(request.expiry.timeIntervalSince1970.rounded(.down)).bigEndian) { Data($0) },
            lengthPrefixed(field: contentDigest(request: request)),
        ] as [Data]).reduce(Data(), +)
    }

    /// The approval signature over `request`, in raw representation. `sign` is the signing function
    /// of the private key, so that a Secure Enclave key and a software key are used the same way.
    public static func signature(
        request: RemoteApprovalRequest,
        sign: (Data) throws -> P256.Signing.ECDSASignature
    ) rethrows -> Data {
        try sign(signedMessage(request: request)).rawRepresentation
    }

    /// Accepts the approval only when `signature` was made by the key behind `publicKey` over
    /// exactly `request`, and `request` has not expired at `now`.
    public static func verify(
        signature: Data?,
        request: RemoteApprovalRequest,
        publicKey: P256.Signing.PublicKey,
        now: Date
    ) throws(RemoteApprovalVerificationError) {
        guard let signature, !signature.isEmpty else {
            throw .missingSignature
        }
        guard let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            throw .malformedSignature
        }
        guard publicKey.isValidSignature(ecdsaSignature, for: signedMessage(request: request)) else {
            throw .signatureMismatch
        }
        guard now < request.expiry else {
            throw .expired
        }
    }

    /// `field` preceded by its length as a 32-bit big-endian integer, so that bytes cannot move
    /// from one field into the next without changing the result.
    static func lengthPrefixed(field: Data) -> Data {
        withUnsafeBytes(of: UInt32(field.count).bigEndian) { Data($0) } + field
    }

    /// The fields, each length-prefixed, one after another.
    static func lengthPrefixedConcatenation(fields: [Data]) -> Data {
        fields.reduce(Data()) { $0 + lengthPrefixed(field: $1) }
    }
}
