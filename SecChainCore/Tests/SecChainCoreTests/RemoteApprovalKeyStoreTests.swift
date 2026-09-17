import Foundation
import Testing

@testable import SecChainCore

/// The Secure Enclave store needs a device and a signed build, so what is covered here is the
/// behavior both stores promise: one key per device, a new key on pairing again, and an unpairing
/// that converges (idempotent).
@Suite
struct RemoteApprovalKeyStoreTests {
    let store = InMemoryRemoteApprovalKeyStore()

    @Test
    func aDeviceHasNoKeyBeforeItIsPaired() throws {
        #expect(try store.existingKey() == nil)
    }

    @Test
    func theCreatedKeyIsTheOneReadBackLater() throws {
        let createdKey = try store.createKey()
        #expect(try store.existingKey()?.publicKeyRepresentation == createdKey.publicKeyRepresentation)
    }

    @Test
    func pairingAgainReplacesTheKeySoThatEveryMacHasToEnrollTheNewOne() throws {
        let firstKey = try store.createKey()
        let secondKey = try store.createKey()
        #expect(firstKey.publicKeyRepresentation != secondKey.publicKeyRepresentation)
        #expect(try store.existingKey()?.publicKeyRepresentation == secondKey.publicKeyRepresentation)
    }

    @Test
    func removingTheKeyTwiceLeavesTheDeviceUnpaired() throws {
        _ = try store.createKey()
        try store.deleteKey()
        try store.deleteKey()
        #expect(try store.existingKey() == nil)
    }
}
