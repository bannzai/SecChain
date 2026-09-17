import Testing

@testable import SecChainCore

@Suite
struct SecChainSharedConfigTests {
    @Test
    func keychainAccessGroupIsPrefixedWithTeamIdentifier() {
        #expect(
            SecChainSharedConfig.keychainAccessGroup
                == "\(SecChainSharedConfig.teamIdentifier).com.bannzai.SecChain.shared"
        )
    }
}
