import CryptoKit
import Foundation

/// Layout version of the remote approval records, stored in every record and matching the `v1` of
/// `RemoteApproval.signedMessagePrefix`. A device that reads a record of another version refuses it
/// instead of guessing what the fields mean.
public let remoteApprovalSchemaVersion = 1

/// Record types of the remote approval protocol in the private database of
/// `SecChainSharedConfig.cloudKitContainerIdentifier` (documents/remote-approval-records.md).
/// They are named here once because a deployed CloudKit record type cannot be deleted, so both
/// front ends and the production schema must agree on the names before the schema is deployed
/// (documents/PROJECT.md, design decision 5).
public enum RemoteApprovalRecordType {
    /// Filed by the Mac that wants an authentication answered on the iPhone.
    public static let request = "ApprovalRequest"
    /// Written by the iPhone. Carries the approval signature, or the fact that the user rejected.
    public static let decision = "ApprovalDecision"
    /// Written by the Mac when it stops waiting, so that the iPhone stops offering the request.
    public static let cancellation = "ApprovalCancellation"
    /// Written by the iPhone to publish the public key of its approval key.
    public static let pairing = "DevicePairing"
}

/// Field names of the record types. One definition, because the CloudKit conversion and the
/// production schema deployment (issue #16) must use the same spellings.
public enum RemoteApprovalRecordField {
    public static let schemaVersion = "schemaVersion"
    public static let requestIdentifier = "requestIdentifier"
    public static let nonce = "nonce"
    public static let expiry = "expiry"
    public static let repositoryIdentity = "repositoryIdentity"
    public static let secretNames = "secretNames"
    public static let commandArguments = "commandArguments"
    public static let requestingDeviceName = "requestingDeviceName"
    public static let outcome = "outcome"
    public static let signature = "signature"
    public static let publicKey = "publicKey"
    public static let deviceName = "deviceName"
}

/// Record names, derived so that the Mac can fetch the iPhone's answer by identifier instead of
/// querying for it (design decision 5: a command-line process cannot receive pushes and polls
/// every 2 seconds). A CloudKit record name is unique within the zone rather than within a record
/// type, which is why each type carries its own prefix.
public enum RemoteApprovalRecordName {
    public static func request(requestIdentifier: UUID) -> String {
        "approval-request-\(requestIdentifier.uuidString)"
    }

    public static func decision(requestIdentifier: UUID) -> String {
        "approval-decision-\(requestIdentifier.uuidString)"
    }

    public static func cancellation(requestIdentifier: UUID) -> String {
        "approval-cancellation-\(requestIdentifier.uuidString)"
    }

    /// Derived from the published key so that publishing the same key twice replaces one record
    /// instead of leaving two, and a new key never overwrites the record of the old one.
    public static func pairing(publicKeyRepresentation: Data) -> String {
        "device-pairing-\(Data(SHA256.hash(data: publicKeyRepresentation).prefix(8)).map { String(format: "%02x", $0) }.joined())"
    }
}

/// One authentication that a Mac asks the paired iPhone to answer. It names what the iPhone shows
/// the user and what the approval signature covers; it never carries a secret value, which is the
/// invariant `.claude/rules/secret-handling.md` and documents/PROJECT.md ("Remote approval") state.
///
/// The Mac keeps its own copy while it waits and verifies against that copy, never against the
/// record read back from CloudKit: any process running as the user can write to the private
/// database, and that process is exactly the actor the *confirm* level exists to stop.
public struct RemoteApprovalRequest: Sendable, Equatable {
    /// Identifies the request, so that an approval of one request cannot be presented for another.
    public let requestIdentifier: UUID
    /// Random bytes chosen for this request only, so that two requests never produce the same
    /// signed message even when every other field is equal.
    public let nonce: Data
    /// The Mac rejects an approval once this moment has passed.
    public let expiry: Date
    /// Repository whose secrets the command reads.
    public let repositoryIdentity: RepositoryIdentity
    /// Names of the secrets the command asks for. Names only; the values stay in the Keychain.
    public let secretNames: [SecretName]
    /// The command the user is about to run, as the words it consists of. `secchain` never accepts
    /// a secret value as an argument (`.claude/rules/secret-handling.md`), so these are safe to
    /// show and to store.
    public let commandArguments: [String]
    /// Name of the Mac that filed the request, so that the user can tell where it came from.
    public let requestingDeviceName: String

    public init(
        requestIdentifier: UUID,
        nonce: Data,
        expiry: Date,
        repositoryIdentity: RepositoryIdentity,
        secretNames: [SecretName],
        commandArguments: [String],
        requestingDeviceName: String
    ) {
        self.requestIdentifier = requestIdentifier
        self.nonce = nonce
        self.expiry = expiry
        self.repositoryIdentity = repositoryIdentity
        self.secretNames = secretNames
        self.commandArguments = commandArguments
        self.requestingDeviceName = requestingDeviceName
    }

    /// Number of random bytes in the nonce. 32 bytes is the output size of the SHA-256 the signed
    /// message is built from, so the nonce is not the weakest part of that message.
    public static let nonceByteCount = 32

    /// A request as a Mac files it at `now`: a fresh identifier, fresh random bytes, and an expiry
    /// `expiryInterval` later. The expiry is truncated to whole seconds because that is the
    /// precision the signature covers (`RemoteApproval.signedMessage`), so the moment stored in
    /// CloudKit and the moment signed cannot disagree.
    public static func filed(
        repositoryIdentity: RepositoryIdentity,
        secretNames: [SecretName],
        commandArguments: [String],
        requestingDeviceName: String,
        now: Date,
        expiryInterval: TimeInterval
    ) -> RemoteApprovalRequest {
        RemoteApprovalRequest(
            requestIdentifier: UUID(),
            nonce: Data((0..<nonceByteCount).map { _ in UInt8.random(in: .min ... .max) }),
            expiry: Date(timeIntervalSince1970: (now.timeIntervalSince1970 + expiryInterval).rounded(.down)),
            repositoryIdentity: repositoryIdentity,
            secretNames: secretNames,
            commandArguments: commandArguments,
            requestingDeviceName: requestingDeviceName
        )
    }
}

/// Whether the iPhone's answer says the user approved or rejected. The raw value is stored in the
/// record, so it must stay stable.
public enum RemoteApprovalOutcome: String, Sendable, CaseIterable {
    case approved
    case rejected
}

/// The iPhone's answer to one request. The record name is derived from the request identifier, so
/// the Mac fetches it by identifier while it polls.
///
/// An approval *is* the signature: `outcome == .approved` with no signature, or with a signature
/// made by another key, is what a record written by anything but the paired iPhone looks like, and
/// verification refuses it. A forged `rejected` only stops a run that the same process could have
/// killed anyway, so a rejection is accepted without a signature.
public struct RemoteApprovalDecision: Sendable, Equatable {
    /// The request this answer belongs to. Informational for the Mac, which fetches by record name
    /// and verifies against its own copy of the request.
    public let requestIdentifier: UUID
    /// What the record says the user chose.
    public let outcome: RemoteApprovalOutcome
    /// The approval signature in P-256 raw representation, `nil` for a rejection or for a record
    /// that carries none.
    public let signature: Data?

    public init(requestIdentifier: UUID, outcome: RemoteApprovalOutcome, signature: Data?) {
        self.requestIdentifier = requestIdentifier
        self.outcome = outcome
        self.signature = signature
    }
}

/// The Mac's notice that it is no longer waiting for an answer (the user pressed Ctrl-C), so that
/// the iPhone stops offering the request. It is a record of its own rather than a field of the
/// answer, because the Mac and the iPhone would otherwise write the same record at the same moment
/// and one of the two writes would be lost.
public struct RemoteApprovalCancellation: Sendable, Equatable {
    /// The request that is no longer waited for.
    public let requestIdentifier: UUID

    public init(requestIdentifier: UUID) {
        self.requestIdentifier = requestIdentifier
    }
}

/// The public key of an iPhone's approval key, as the iPhone publishes it for the Macs to enroll
/// (design decision 5: pairing compares a short number on both screens).
public struct RemoteApprovalPairing: Codable, Sendable, Equatable {
    /// P-256 public key in X9.63 representation, the form `P256.Signing.PublicKey` reads and
    /// writes without a container format.
    public let publicKeyRepresentation: Data
    /// Name of the iPhone, so that the user recognizes which device published the key.
    public let deviceName: String

    public init(publicKeyRepresentation: Data, deviceName: String) {
        self.publicKeyRepresentation = publicKeyRepresentation
        self.deviceName = deviceName
    }

    /// The key the Mac verifies approvals with. Throws when the published bytes are not a P-256
    /// public key, because a Mac must not enroll something it cannot verify with.
    public func publicKey() throws -> P256.Signing.PublicKey {
        do {
            return try P256.Signing.PublicKey(x963Representation: publicKeyRepresentation)
        } catch {
            throw RemoteApprovalRecordError.malformedField(name: RemoteApprovalRecordField.publicKey)
        }
    }

    /// The number shown on the Mac and on the iPhone so that the user can see they are enrolling
    /// the key of their own phone.
    public var verificationNumber: String {
        RemoteApprovalPairing.verificationNumber(publicKeyRepresentation: publicKeyRepresentation)
    }

    /// Digits of the number both screens show. 12 digits in three groups of four: the number must
    /// be read out and compared by a person, while being long enough that generating keys until
    /// one of them produces the number of the user's phone is expensive. A P-256 key pair plus a
    /// SHA-256 costs on the order of tens of microseconds, so 6 digits would be matched in
    /// seconds, while 12 digits take about a million times as long.
    public static let verificationNumberDigitCount = 12
    /// Digits per group, chosen so that the number is read in three chunks like a phone number.
    public static let verificationNumberGroupSize = 4

    /// The number derived from the SHA-256 of the published key (design decision 5). Both devices
    /// derive it the same way from the same bytes, so a mismatch means they are not looking at the
    /// same key.
    public static func verificationNumber(publicKeyRepresentation: Data) -> String {
        let digits = String(
            format: "%0\(verificationNumberDigitCount)llu",
            Data(SHA256.hash(data: publicKeyRepresentation))
                .prefix(8)
                .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                % (0..<verificationNumberDigitCount).reduce(UInt64(1)) { total, _ in total * 10 }
        )
        return stride(from: 0, to: digits.count, by: verificationNumberGroupSize)
            .map { String(digits.dropFirst($0).prefix(verificationNumberGroupSize)) }
            .joined(separator: "-")
    }
}

/// Why a record read from CloudKit cannot be used. Every case names the field, so that a schema
/// that does not match the one this build expects is reported instead of silently ignored.
public enum RemoteApprovalRecordError: Error, Equatable, CustomStringConvertible {
    /// The record is of another record type than the one that was asked for.
    case unexpectedRecordType(expected: String, found: String)
    /// The record does not carry a field this version needs.
    case missingField(name: String)
    /// The field is there but cannot be read as the type the protocol defines.
    case malformedField(name: String)
    /// The record was written against another layout of the protocol.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unexpectedRecordType(let expected, let found):
            "Expected a \(expected) record, found \(found)."
        case .missingField(let name):
            "The record has no \(name) field."
        case .malformedField(let name):
            "The record's \(name) field cannot be read."
        case .unsupportedSchemaVersion(let found, let supported):
            "The record uses remote approval schema version \(found); this build supports version \(supported). Update SecChain on both devices."
        }
    }
}
