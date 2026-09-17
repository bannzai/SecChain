import ArgumentParser
import Foundation
import SecChainCore

/// `secchain pair`: which iPhone may answer this Mac's authentications, and whether it is asked by
/// default (documents/PROJECT.md, design decision 5). Each Mac is paired separately.
struct PairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair this Mac with your iPhone, so that it can approve authentications for you.",
        discussion: """
            Open SecChain on your iPhone and start pairing there; the iPhone publishes its approval \
            key to your private iCloud database. Then run 'secchain pair' here and type the number \
            your iPhone shows. Only the key you enroll can approve, so nothing else that reaches \
            your iCloud account can answer for you.

            Run 'secchain pair status' to see the pairing, 'secchain pair confirm-on-iphone on' to \
            have the iPhone asked without --approve-remotely, and 'secchain pair remove' to stop it.
            """,
        subcommands: [PairEnrollCommand.self, PairStatusCommand.self, PairConfirmOnIPhoneCommand.self, PairRemoveCommand.self],
        defaultSubcommand: PairEnrollCommand.self
    )
}

/// `secchain pair [--number ...]`: enroll the key of the iPhone whose number the user confirms.
struct PairEnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Enroll your iPhone's approval key after comparing the number shown on both screens.",
        discussion: "Asks for Touch ID or your password before the key is stored. This is the default subcommand, so 'secchain pair' does the same."
    )

    @Option(
        name: .long,
        help: "The number your iPhone shows. Without it, the number is asked for on the terminal. Spaces and dashes are ignored."
    )
    var number: String?

    func run() async throws {
        let publishedPairings = try await CloudKitRemoteApprovalStore.system().pairings()
        guard !publishedPairings.isEmpty else {
            throw RemoteApprovalPairingError.noPublishedKey
        }
        for pairing in publishedPairings {
            reportToStandardError(line: "a key published by \(pairing.deviceName) shows the number \(pairing.verificationNumber)")
        }
        let enrolledPairing = try await RemoteApprovalPairingStore.system.enroll(
            publishedPairings: publishedPairings,
            number: try number ?? numberFromTheTerminal()
        )
        print("Paired this Mac with \(enrolledPairing.pairing.deviceName) (\(enrolledPairing.pairing.verificationNumber)).")
        print("Authentications still happen on this Mac. Use 'secchain run --approve-remotely', or 'secchain pair confirm-on-iphone on' to ask your iPhone by default.")
    }

    /// Asks for the number on the terminal. Typing it, rather than answering yes to a number
    /// SecChain printed, is what makes the comparison a comparison.
    func numberFromTheTerminal() throws -> String {
        print("Type the number your iPhone shows: ", terminator: "")
        guard let typedNumber = readLine(strippingNewline: true) else {
            throw ValidationError("No number was given. Pass it with --number when there is no terminal to read from.")
        }
        return typedNumber
    }
}

/// `secchain pair status`: what this Mac has enrolled. Reads nothing that needs authentication.
struct PairStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show which iPhone is paired with this Mac, and whether it is asked by default."
    )

    func run() async throws {
        guard let enrolledPairing = try RemoteApprovalPairingStore.system.enrolledPairing() else {
            print("This Mac is not paired with an iPhone. Authentications are answered here, and fail where no prompt can be shown.")
            return
        }
        print("Paired with \(enrolledPairing.pairing.deviceName) (\(enrolledPairing.pairing.verificationNumber)).")
        print(
            enrolledPairing.answersConfirmOnTheIPhone
                ? "Confirm authentications go to that iPhone by default."
                : "Confirm authentications are answered on this Mac, and go to that iPhone with --approve-remotely or when no prompt can be shown here."
        )
    }
}

/// `secchain pair confirm-on-iphone <on|off>`: the per-Mac setting of design decision 5.
struct PairConfirmOnIPhoneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm-on-iphone",
        abstract: "Answer confirm authentications on the paired iPhone by default, or stop doing so.",
        discussion: "For a Mac without Touch ID, and for commands an AI coding agent starts while you are away from the Mac. Asks for Touch ID or your password before the setting changes."
    )

    @Argument(help: "'on' to ask the iPhone by default, 'off' to ask on this Mac again.")
    var state: OnOrOff

    func run() async throws {
        let enrolledPairing = try await RemoteApprovalPairingStore.system.setAnswersConfirmOnTheIPhone(
            answersConfirmOnTheIPhone: state == .on
        )
        print(
            enrolledPairing.answersConfirmOnTheIPhone
                ? "Confirm authentications now go to \(enrolledPairing.pairing.deviceName) by default."
                : "Confirm authentications are answered on this Mac again."
        )
    }
}

/// `secchain pair remove`: forget the enrolled key.
struct PairRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop letting your iPhone answer authentications on this Mac.",
        discussion: "Asks for Touch ID or your password first. Removing a pairing that is not there succeeds."
    )

    func run() async throws {
        try await RemoteApprovalPairingStore.system.remove()
        print("This Mac is not paired with an iPhone any more. Authentications are answered here.")
    }
}

/// The two states of a switch on the command line, so that `on` and `off` are the only words
/// accepted and the help lists them.
enum OnOrOff: String, ExpressibleByArgument, CaseIterable {
    case on
    case off
}
