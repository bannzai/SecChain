#if os(iOS)
import SwiftUI

/// Explains why iPhone and iPad can show fewer secrets than a Mac: a secret that a Mac keeps to
/// itself never reaches them, so a repository would otherwise look incomplete or be missing
/// without a reason (documents/PROJECT.md, "iOS app").
struct MacOnlySecretsNote: View {
    var body: some View {
        Text("Secrets set to This device only or Device-bound on a Mac stay on that Mac and do not appear here", bundle: .module)
    }
}
#endif
