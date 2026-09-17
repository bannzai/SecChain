#if os(iOS)
import SecChainCore
import SwiftUI

/// What one Mac is asking to be approved, and the two answers to it. It is the screen a
/// notification leads to, so everything the approval covers is on it at once: which Mac asked, for
/// which repository, which secrets, which command, and how long the Mac still waits.
struct RemoteApprovalRequestView: View {
    /// Holds the key that signs and the state of the answer.
    let model: RemoteApprovalModel
    /// The request being answered. Kept by the screen rather than looked up again, so that it stays
    /// readable after it has been answered and left the list of open requests.
    let request: RemoteApprovalRequest

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The remaining time is part of what the user decides on, so it counts down on screen
        // instead of being read once when the screen opened.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .navigationTitle(String(localized: "Approval", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    func content(now: Date) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline
                    details
                    status(now: now)
                    if let failureMessage = model.failureMessage {
                        Text(failureMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            actions(now: now)
        }
    }

    var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approval requested", bundle: .module)
                .font(.largeTitle.bold())
            Text("Only this iPhone can sign it", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Everything the signature covers, in the order the user reads it: who asked, where, for what,
    /// and what will run.
    var details: some View {
        VStack(spacing: 0) {
            detailRow(
                label: String(localized: "Mac", bundle: .module),
                icon: "laptopcomputer",
                text: Text(request.requestingDeviceName)
            )
            Divider()
            detailRow(
                label: String(localized: "Repository", bundle: .module),
                icon: "folder",
                text: Text(request.repositoryIdentity.value)
            )
            Divider()
            detailRow(
                label: String(localized: "Secrets", bundle: .module),
                icon: "key",
                text: Text(request.secretNames.map(\.value).joined(separator: "\n")).font(.body.monospaced())
            )
            Divider()
            detailRow(
                label: String(localized: "Command", bundle: .module),
                icon: "terminal",
                text: Text(request.commandArguments.joined(separator: " ")).font(.body.monospaced())
            )
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    func detailRow(label: String, icon: String, text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                text
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    /// The remaining time while the Mac waits, and what happened once it does not.
    @ViewBuilder
    func status(now: Date) -> some View {
        switch outcome(now: now) {
        case .waiting:
            banner(icon: "clock", tint: .accentColor) {
                Text("Time left", bundle: .module)
            } detail: {
                Text(Duration.seconds(max(0, request.expiry.timeIntervalSince(now))).formatted(.time(pattern: .minuteSecond)))
                    .font(.title.monospacedDigit())
            }
        case .approved:
            banner(icon: "checkmark.seal.fill", tint: .green) {
                Text("Approved", bundle: .module)
            } detail: {
                Text("Your Mac can read the secrets for this command", bundle: .module)
            }
        case .rejected:
            banner(icon: "hand.raised.fill", tint: .orange) {
                Text("Rejected", bundle: .module)
            } detail: {
                Text("Your Mac was told not to read the secrets", bundle: .module)
            }
        case .expired:
            banner(icon: "clock.badge.xmark", tint: .secondary) {
                Text("This request has expired", bundle: .module)
            } detail: {
                Text("Run the command again on your Mac to ask once more", bundle: .module)
            }
        case .cancelled:
            banner(icon: "xmark.circle", tint: .secondary) {
                Text("The Mac stopped waiting", bundle: .module)
            } detail: {
                Text("Run the command again on your Mac to ask once more", bundle: .module)
            }
        }
    }

    func banner(
        icon: String,
        tint: Color,
        @ViewBuilder title: () -> Text,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                title()
                    .font(.headline)
                detail()
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    func actions(now: Date) -> some View {
        VStack(spacing: 12) {
            if outcome(now: now) == .waiting {
                Button {
                    Task {
                        await model.approve(request: request)
                    }
                } label: {
                    Text("Approve", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(role: .destructive) {
                    Task {
                        await model.reject(request: request)
                    }
                } label: {
                    Text("Reject", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .disabled(model.isAnswering)
        .padding()
        .background(.bar)
    }

    /// What the screen shows about the request. The expiry is read from the request itself rather
    /// than from the model, so the screen stops offering an approval the moment the Mac stops
    /// accepting one, without waiting for a refresh.
    func outcome(now: Date) -> Outcome {
        if let answeredOutcome = model.answeredOutcome {
            return answeredOutcome == .approved ? .approved : .rejected
        }
        if model.unanswerableReason == .cancelled {
            return .cancelled
        }
        return now < request.expiry ? .waiting : .expired
    }

    /// The states the approval screen has. They are not the record's outcome alone, because a
    /// request that nobody answered also has an end.
    enum Outcome {
        case waiting
        case approved
        case rejected
        case expired
        case cancelled
    }
}
#endif
