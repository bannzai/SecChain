#if DEBUG
import SecChainCore
import SwiftUI

/// Runs the doctor's Secure Enclave and CloudKit checks inside the app and lists the result lines.
/// The approving device is an iPhone, where the doctor's launch arguments cannot be passed from a
/// remote session (simtunnel) or from the device itself, so the checks are offered on screen.
struct RemoteApprovalChecksView: View {
    /// Result lines, `nil` while the checks run.
    @State private var lines: [String]?

    var body: some View {
        NavigationStack {
            Group {
                if let lines {
                    List(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView("Running checks")
                }
            }
            .navigationTitle("Remote Approval Checks")
        }
        .task {
            // The Secure Enclave results are shown before CloudKit answers, so that they stay
            // readable even if CloudKit stops the app (a build without the container entitlement).
            let secureEnclaveLines = KeychainDoctor.runSecureEnclaveChecks().map(\.line)
            lines = secureEnclaveLines
            lines = secureEnclaveLines + (await KeychainDoctor.runCloudKitChecks()).map(\.line) + ["done"]
        }
    }
}
#endif
