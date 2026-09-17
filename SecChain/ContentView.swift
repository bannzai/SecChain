import SecChainUI
import SwiftUI

/// Root view of the macOS app: the shared screens, sized for a desktop window.
struct ContentView: View {
    let model: AppModel

    var body: some View {
        RootView(model: model)
            .frame(minWidth: 720, minHeight: 440)
    }
}
