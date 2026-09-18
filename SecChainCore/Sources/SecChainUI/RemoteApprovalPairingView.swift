#if os(iOS)
import SecChainCore
import SwiftUI

/// Pairing this iPhone with the user's Macs, and the way to the requests that are waiting.
///
/// The number in the middle is the whole of the pairing check: both screens derive it from the same
/// published key, so a number that matches means the Mac is about to enroll the key of this iPhone
/// and not of some other device (documents/PROJECT.md, design decision 5).
public struct RemoteApprovalPairingView: View {
    /// Holds the key of this device and the requests waiting for it.
    let model: RemoteApprovalModel

    @Environment(\.dismiss) private var dismiss

    public init(model: RemoteApprovalModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            form
                .navigationTitle(String(localized: "Remote Approval", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", bundle: .module)) {
                            dismiss()
                        }
                    }
                }
                .navigationDestination(
                    isPresented: Binding(
                        get: { model.presentedRequest != nil },
                        set: { isPresented in
                            if !isPresented {
                                model.dismissRequest()
                            }
                        }
                    )
                ) {
                    if let presentedRequest = model.presentedRequest {
                        RemoteApprovalRequestView(model: model, request: presentedRequest)
                    }
                }
        }
        .task {
            await model.refresh()
        }
    }

    var form: some View {
        Form {
            pairingSection
            notificationSection
            requestSection
            if model.pairing != nil {
                pairingChangeSection
            }
            if let failureMessage = model.failureMessage {
                Section {
                    Text(failureMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var pairingSection: some View {
        if let pairing = model.pairing {
            Section {
                VStack(spacing: 8) {
                    Text(pairing.verificationNumber)
                        .font(.system(.title, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Text(pairing.deviceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                Label {
                    model.isPairingPublished
                        ? Text("Your Macs can find this key", bundle: .module)
                        : Text("This key has not reached iCloud yet", bundle: .module)
                } icon: {
                    Image(systemName: model.isPairingPublished ? "checkmark.icloud" : "exclamationmark.icloud")
                        .foregroundStyle(model.isPairingPublished ? Color.green : Color.orange)
                }
            } header: {
                Text("This iPhone", bundle: .module)
            } footer: {
                Text("Your Mac shows the same number while it pairs. Confirm it there only when the two match", bundle: .module)
            }
        } else {
            Section {
                Button {
                    Task {
                        await model.pair()
                    }
                } label: {
                    Label(String(localized: "Pair This iPhone", bundle: .module), systemImage: "iphone.and.arrow.right.inward")
                }
            } header: {
                Text("This iPhone", bundle: .module)
            } footer: {
                Text("SecChain creates a key in the Secure Enclave of this iPhone and publishes only its public key in your private iCloud database. The key itself never leaves this iPhone", bundle: .module)
            }
        }
    }

    var notificationSection: some View {
        Section {
            if model.isNotificationAllowed {
                Label {
                    Text("Notifications are on", bundle: .module)
                } icon: {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(Color.green)
                }
            } else {
                Button {
                    Task {
                        await model.enableNotifications()
                    }
                } label: {
                    Label(String(localized: "Allow Notifications", bundle: .module), systemImage: "bell")
                }
            }
        } header: {
            Text("Notifications", bundle: .module)
        } footer: {
            Text("A request from a Mac arrives as a notification. SecChain also looks for waiting requests every time you open it, because a notification can be delayed or dropped", bundle: .module)
        }
    }

    @ViewBuilder
    var requestSection: some View {
        Section {
            if model.openRequests.isEmpty {
                Text("No Mac is waiting for an approval", bundle: .module)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.openRequests, id: \.requestIdentifier) { request in
                    Button {
                        model.present(request: request)
                    } label: {
                        requestRow(request: request)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Waiting", bundle: .module)
        }
    }

    /// One waiting request: the Mac that asked and the command it wants to run, which is what tells
    /// two requests apart at a glance.
    func requestRow(request: RemoteApprovalRequest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.requestingDeviceName)
                Text(approvedCommandText(commandArguments: request.commandArguments))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
    }

    var pairingChangeSection: some View {
        Section {
            Button {
                Task {
                    await model.pair()
                }
            } label: {
                Label(String(localized: "Pair Again", bundle: .module), systemImage: "arrow.trianglehead.2.clockwise")
            }
            Button(role: .destructive) {
                Task {
                    await model.unpair()
                }
            } label: {
                Label(String(localized: "Remove Pairing", bundle: .module), systemImage: "trash")
            }
        } footer: {
            Text("Pairing again replaces the key of this iPhone, and removing the pairing takes it away. Either way every Mac has to pair once more before it can ask this iPhone again", bundle: .module)
        }
    }
}
#endif
