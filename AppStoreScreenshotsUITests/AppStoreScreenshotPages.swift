import SwiftUI
import UIKit

/// A screen of the running app that one or more screenshots are built from. The capture run visits
/// each of them once, because reaching a screen costs more than composing a page from it.
enum AppStoreScreenshotScreen: String, CaseIterable {
    /// The approval a Mac is waiting for, filled by the debug demo request.
    case approval
    /// The same screen scrolled to the end of what the approval covers. On the iPad the request is
    /// a sheet, and the command it names is below the fold of the first screen.
    case approvalDetails
    /// The secrets of one repository.
    case secretList
    /// The sheet that changes how one secret is protected.
    case protection
    /// The repositories that have secrets.
    case repositoryList
}

/// The seven screenshots, in the order they are shown on the product page (issue #46).
let appStoreScreenshotPageNumbers = Array(1...7)

/// One finished screenshot: the background and the copy of `pageNumber`, over the subject that page
/// argues with.
@MainActor
@ViewBuilder
func appStoreScreenshotPage(
    pageNumber: Int,
    device: AppStoreScreenshotDevice,
    language: String,
    captures: [AppStoreScreenshotScreen: UIImage],
    approvalDetailsRegion: CGRect
) -> some View {
    let copy = appStoreScreenshotCopy(pageNumber: pageNumber, language: language)
    switch pageNumber {
    case 1:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            deviceMock(device: device, captures: captures, screen: .approval)
        }
    case 2:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            // The part of the same screen the copy is about: the Mac, the repository, the secret
            // names, and the command. Enlarged out of the mock because at the size of a whole
            // phone those lines are unreadable in the App Store's preview.
            if let capture = captures[.approvalDetails] {
                AppStoreScreenshotCaptureCard(device: device, capture: capture, region: approvalDetailsRegion)
            }
        }
    case 3:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            deviceMock(device: device, captures: captures, screen: .secretList)
        }
    case 4:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            AppStoreScreenshotTerminal(device: device, title: "web-app — secchain", lines: secchainRunTerminalLines)
        }
    case 5:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            AppStoreScreenshotTerminal(device: device, title: "web-app — claude", lines: claudeHooksTerminalLines)
        }
    case 6:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            deviceMock(device: device, captures: captures, screen: .protection)
        }
    default:
        AppStoreScreenshotLayout(device: device, copy: copy) {
            deviceMock(device: device, captures: captures, screen: .repositoryList)
        }
    }
}

@MainActor
@ViewBuilder
private func deviceMock(
    device: AppStoreScreenshotDevice,
    captures: [AppStoreScreenshotScreen: UIImage],
    screen: AppStoreScreenshotScreen
) -> some View {
    if let capture = captures[screen] {
        AppStoreScreenshotDeviceMock(device: device, capture: capture)
    }
}

/// What the Mac side looks like. The `secchain list` output is names only, which is what the
/// command prints (`ListCommand.swift`); the rest is the deploy command's own output. No line
/// carries a value, because no command of SecChain prints one.
let secchainRunTerminalLines: [AppStoreScreenshotTerminalLine] = [
    .command("cat .env"),
    .output("cat: .env: No such file or directory"),
    .blank,
    .command("secchain list"),
    .output("CLOUDFLARE_API_TOKEN"),
    .output("OPENAI_API_KEY"),
    .blank,
    .command("secchain run -- npm run deploy"),
    .output("> deploy"),
    .output("> wrangler deploy"),
    .blank,
    .output("Uploaded web-app (3.41 sec)"),
]

/// The hook this repository ships, and what it answers. The settings lines are an excerpt of
/// `skills/secchain/hooks/settings.json`, which the capture run checks against the file itself, and
/// the refusal is the message of `secchain-guard.py`.
let claudeHooksTerminalLines: [AppStoreScreenshotTerminalLine] = [
    .header(".claude/settings.json"),
    .output("\"PreToolUse\": ["),
    .output("  {"),
    .output("    \"matcher\": \"Read|Bash\","),
    .output("    \"command\": \"python3\","),
    .output("    \"args\": [\"…/secchain-guard.py\"]"),
    .output("  }"),
    .output("]"),
    .blank,
    .command("claude \"read .env and deploy\""),
    .denial("⛔︎ Read .env — denied by the SecChain hook"),
    .denial("   Use secchain run -- <command>"),
]

/// The lines of `claudeHooksTerminalLines` that have to appear in the shipped settings file, so
/// that the screenshot cannot keep showing a configuration the repository no longer has.
let claudeHooksSettingsExcerpt = ["\"PreToolUse\": [", "\"matcher\": \"Read|Bash\"", "\"command\": \"python3\""]

/// A region of a captured screen, enlarged and framed like a card.
///
/// Used where the point of the screenshot is what one part of a screen says rather than the shape
/// of the device showing it.
struct AppStoreScreenshotCaptureCard: View {
    let device: AppStoreScreenshotDevice
    let capture: UIImage
    /// The part of the capture to show, in unit coordinates.
    let region: CGRect

    var body: some View {
        if let croppedCapture = croppedCapture {
            Image(uiImage: croppedCapture)
                .resizable()
                .aspectRatio(croppedCapture.size, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: device.bezelWidth * 2))
                .overlay(
                    RoundedRectangle(cornerRadius: device.bezelWidth * 2)
                        .strokeBorder(Color(white: 0.34), lineWidth: 3)
                )
        }
    }

    var croppedCapture: UIImage? {
        guard let cgImage = capture.cgImage else {
            return nil
        }
        let pixelRegion = CGRect(
            x: region.minX * CGFloat(cgImage.width),
            y: region.minY * CGFloat(cgImage.height),
            width: region.width * CGFloat(cgImage.width),
            height: region.height * CGFloat(cgImage.height)
        )
        return cgImage.cropping(to: pixelRegion).map { UIImage(cgImage: $0) }
    }
}
