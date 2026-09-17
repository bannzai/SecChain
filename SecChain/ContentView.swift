import SecChainCore
import SwiftUI

/// Root view of the macOS app. It only proves that the app links `SecChainCore`; repository and
/// secret management replace it.
struct ContentView: View {
    var body: some View {
        Text(SecChainSharedConfig.keychainAccessGroup)
            .padding()
    }
}
