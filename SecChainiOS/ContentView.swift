import SecChainUI
import SwiftUI

/// Root view of the iOS app: the screens shared with the macOS app.
struct ContentView: View {
    /// State of the shared screens, owned by the app.
    let model: AppModel

    var body: some View {
        RootView(model: model)
    }
}
