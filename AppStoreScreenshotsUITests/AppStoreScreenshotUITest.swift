import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Captures the screens the App Store screenshots are built from, composes the seven pages over
/// them, and attaches each page as the PNG that goes to App Store Connect (issue #46).
///
/// A run covers the one language `SCREENSHOT_LANGUAGE` names: the status bar in the picture belongs
/// to the simulator, and a simulator is in one language at a time, so the capture script sets the
/// language and starts a run per language. The device class comes from the simulator the run was
/// started on (`AppStoreScreenshotDevice.current`), so the generation script decides it by choosing
/// the destination.
final class AppStoreScreenshotUITest: XCTestCase {
    /// The languages App Store Connect gets screenshots for. They are also the localizations of
    /// `AppStoreScreenshotCopy.xcstrings` and of `fastlane/metadata/`.
    let screenshotLanguages = ["en", "ja"]
    /// The languages this run captures. A run started by hand, without the variable the capture
    /// script sets, covers every language and leaves the status bar in the simulator's language.
    var capturedLanguages: [String] {
        guard let language = ProcessInfo.processInfo.environment["SCREENSHOT_LANGUAGE"] else {
            return screenshotLanguages
        }
        return [language]
    }
    /// Repository of the demo data whose secrets cover every protection level and both
    /// synchronization states (`AppModelFactory.demoStore`).
    let demoRepositoryIdentity = "github.com/example/web-app"
    /// Secret of that repository the protection sheet is opened for. It is already at the
    /// `confirm` level, so the sheet shows the level that the screenshot argues for.
    let demoSecretName = "CLOUDFLARE_API_TOKEN"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        try assertSettingsExcerptMatchesTheShippedHook()
        assertCopyIsTranslated()
        XCTAssertTrue(
            capturedLanguages.allSatisfy(screenshotLanguages.contains),
            "SCREENSHOT_LANGUAGE names \(capturedLanguages), which AppStoreScreenshotCopy.xcstrings has no copy for"
        )
        let device = AppStoreScreenshotDevice.current
        // The app's screen is the light surface the dark canvas sets off; the capture script sets
        // the same appearance on the simulator.
        XCUIDevice.shared.appearance = .light
        // App Store Connect takes portrait pictures for both classes, and an iPad simulator can
        // start in landscape.
        XCUIDevice.shared.orientation = .portrait
        for language in capturedLanguages {
            let (captures, approvalDetailsRegion) = capturedScreens(language: language)
            for pageNumber in appStoreScreenshotPageNumbers {
                let page = appStoreScreenshotPage(
                    pageNumber: pageNumber,
                    device: device,
                    language: language,
                    captures: captures,
                    approvalDetailsRegion: approvalDetailsRegion
                )
                let attachment = XCTAttachment(
                    data: try pngData(view: page, size: device.canvasSize),
                    uniformTypeIdentifier: "public.png"
                )
                // Parsed by scripts/generate_screenshots/organize_appstore_screenshots.sh.
                attachment.name = "screenshot---\(language)---\(device.fileNameComponent)---\(pageNumber)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// Every page has copy in every language. `localizedString` answers with the key itself when
    /// the catalog was not compiled into the bundle, which would otherwise ship a screenshot that
    /// reads `page1.title`.
    func assertCopyIsTranslated() {
        for language in screenshotLanguages {
            for pageNumber in appStoreScreenshotPageNumbers {
                let copy = appStoreScreenshotCopy(pageNumber: pageNumber, language: language)
                XCTAssertFalse(
                    copy.title.hasPrefix("page") || copy.subtitle.hasPrefix("page"),
                    "Page \(pageNumber) has no \(language) copy in AppStoreScreenshotCopy.xcstrings"
                )
            }
        }
    }

    /// The hook configuration the fifth screenshot shows is the one the repository ships. Without
    /// this check the screenshot could keep showing a configuration that has been changed since.
    func assertSettingsExcerptMatchesTheShippedHook() throws {
        let settingsURL = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "settings", withExtension: "json"),
            "settings.json of skills/secchain/hooks is not in the test bundle"
        )
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        for line in claudeHooksSettingsExcerpt {
            XCTAssertTrue(
                settings.contains(line),
                "The fifth screenshot shows \(line), which skills/secchain/hooks/settings.json no longer has"
            )
        }
    }

    // MARK: - The screens of the app

    /// Launches the app in `language`, walks to every screen a page needs, and returns the captures
    /// together with where the approval's details sit on the screen they were captured from.
    ///
    /// Everything on these screens comes from the app's debug demo data (`AppModel.useDemoStore`,
    /// `RemoteApprovalModel.useDemoData`): dummy values under example repositories, so that no
    /// secret value, no real public key, and nothing personal can reach a screenshot.
    @MainActor
    func capturedScreens(language: String) -> ([AppStoreScreenshotScreen: UIImage], CGRect) {
        var captures: [AppStoreScreenshotScreen: UIImage] = [:]

        let appWithDemoSecrets = launchedApp(language: language)
        tapDebugButton(app: appWithDemoSecrets, label: "Use Demo Data")
        captures[.repositoryList] = screenCapture(app: appWithDemoSecrets)
        openDemoRepository(app: appWithDemoSecrets)
        captures[.secretList] = screenCapture(app: appWithDemoSecrets)
        openProtectionOfDemoSecret(app: appWithDemoSecrets)
        captures[.protection] = screenCapture(app: appWithDemoSecrets)
        appWithDemoSecrets.terminate()

        // A second launch rather than a way back: the debug controls live in the toolbar of the
        // repository list, and the protection sheet was opened two screens away from it.
        let appWithDemoApproval = launchedApp(language: language)
        // Also demo secrets, because on the iPad the request is a sheet over the repository list,
        // which would otherwise say that there are none.
        tapDebugButton(app: appWithDemoApproval, label: "Use Demo Data")
        tapDebugButton(app: appWithDemoApproval, label: "Use Demo Remote Approval")
        // The screen appears once the demo request has been filed and read back.
        XCTAssertTrue(
            localizedButton(app: appWithDemoApproval, english: "Approve", japanese: "承認").waitForExistence(timeout: 60),
            "The approval screen did not appear. UI: \(appWithDemoApproval.debugDescription)"
        )
        captures[.approval] = screenCapture(app: appWithDemoApproval)
        // What the approval covers ends with the command, which is below the fold of the sheet the
        // iPad shows. On the iPhone the request fits, and the scroll view stays where it is.
        let requestScrollView = appWithDemoApproval.scrollViews.firstMatch
        if requestScrollView.waitForExistence(timeout: 5) {
            requestScrollView.swipeUp()
        }
        captures[.approvalDetails] = screenCapture(app: appWithDemoApproval)
        let approvalDetailsRegion = approvalDetailsRegion(app: appWithDemoApproval)
        appWithDemoApproval.terminate()

        return (captures, approvalDetailsRegion)
    }

    /// The card that holds the four rows the approval covers, in unit coordinates of the capture.
    ///
    /// Read off the screen rather than written down as a measured rectangle: the card is as tall as
    /// the request's own text, and on the iPad it sits in a sheet the system places. Its edges are
    /// derived from the two paddings `RemoteApprovalRequestView` gives it — one around the content
    /// of the scroll view, one inside every row — so that neither the buttons below the card nor
    /// the screen behind the sheet can end up in the picture.
    @MainActor
    func approvalDetailsRegion(app: XCUIApplication) -> CGRect {
        // SwiftUI's `.padding()` without a length, which is what both places use.
        let defaultPadding: CGFloat = 16
        // The label of the first row. It reads "Mac" in both languages, so the query needs no
        // translation the way the buttons of `localizedButton` do.
        let firstRowLabel = app.staticTexts["Mac"].firstMatch
        // The last row is the command, whose last argument the demo request ends with.
        let lastRowValue = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "production")).firstMatch
        XCTAssertTrue(
            firstRowLabel.waitForExistence(timeout: 10),
            "The approval screen has no Mac row to measure the card from. UI: \(app.debugDescription)"
        )
        XCTAssertTrue(
            lastRowValue.waitForExistence(timeout: 10),
            "The approval screen has no command row to measure the card from. UI: \(app.debugDescription)"
        )
        let scrollViewFrame = app.scrollViews.firstMatch.frame
        let cardTop = firstRowLabel.frame.minY - defaultPadding
        let card = CGRect(
            x: scrollViewFrame.minX + defaultPadding,
            y: cardTop,
            width: scrollViewFrame.width - 2 * defaultPadding,
            height: lastRowValue.frame.maxY + defaultPadding - cardTop
        )
        // The window of the app being captured, which is what a capture covers. Not the runner
        // process's own `UIScreen`, which has no scene of its own and answers 320x480.
        let screenSize = app.windows.firstMatch.frame.size
        print("approval details card \(card) in window \(screenSize), scroll view \(scrollViewFrame)")
        return CGRect(
            x: card.minX / screenSize.width,
            y: card.minY / screenSize.height,
            width: card.width / screenSize.width,
            height: card.height / screenSize.height
        )
    }

    @MainActor
    func launchedApp(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "ja" ? "ja_JP" : "en_US",
        ]
        app.launch()
        return app
    }

    /// A button of the app by its text in the language being captured. The two texts are the
    /// English and the Japanese of `SecChainUI`'s String Catalog.
    @MainActor
    func localizedButton(app: XCUIApplication, english: String, japanese: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", english, japanese)).firstMatch
    }

    /// A row of a list by a text it shows. Rows are found this way rather than by position because
    /// the lists are sorted by identifier and by name, which a change to the demo data would
    /// reorder without failing.
    @MainActor
    func rowContaining(app: XCUIApplication, text: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@", text)).firstMatch
    }

    @MainActor
    func screenCapture(app: XCUIApplication) -> UIImage {
        // The animation of a sheet or a push is not over the moment its content exists.
        Thread.sleep(forTimeInterval: 1)
        return app.screenshot().image
    }

    /// Taps a control of the debug menu, which sits behind the overflow item of the repository
    /// list's toolbar on a narrow screen and beside it on a wide one.
    @MainActor
    func tapDebugButton(app: XCUIApplication, label: String) {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 5), button.isHittable {
            button.tap()
            return
        }
        // The identifier of the item iOS puts secondary toolbar actions behind. Its label is the
        // system's own ("More", "さらに表示"), not the name the app gives the menu.
        let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "No overflow menu in the toolbar. UI: \(app.debugDescription)")
        overflow.tap()
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(label) is not in the menu. UI: \(app.debugDescription)")
        button.tap()
    }

    /// The demo repository whose secrets show all three protection levels and both synchronization
    /// states (`AppModelFactory.demoStore`), which is what the third screenshot is about.
    @MainActor
    func openDemoRepository(app: XCUIApplication) {
        let row = rowContaining(app: app, text: demoRepositoryIdentity)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The repository list has no demo repository. UI: \(app.debugDescription)")
        row.tap()
    }

    /// Opens the protection sheet of a demo secret through the menu of its row.
    @MainActor
    func openProtectionOfDemoSecret(app: XCUIApplication) {
        let row = rowContaining(app: app, text: demoSecretName)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The secret list has no demo secret. UI: \(app.debugDescription)")
        let rowMenu = row.buttons.firstMatch
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 10), "The secret's row has no menu. UI: \(app.debugDescription)")
        rowMenu.tap()
        let changeProtection = localizedButton(app: app, english: "Change Protection", japanese: "保護レベルを変更")
        XCTAssertTrue(changeProtection.waitForExistence(timeout: 10), "The row menu has no protection item. UI: \(app.debugDescription)")
        changeProtection.tap()
    }

    // MARK: - The delivered image

    /// Renders `view` at one pixel per point and encodes it as a PNG without an alpha channel,
    /// which is what App Store Connect accepts.
    ///
    /// The bitmap is built with `CGContext` rather than with `UIGraphicsImageRenderer`, because
    /// `UIImage.pngData()` writes an RGBA PNG (color type 6) even for an image drawn into an opaque
    /// context, while ImageIO writes color type 2 for an image whose alpha info is `noneSkipLast`.
    @MainActor
    func pngData(view: some View, size: CGSize) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.cgImage, "The page could not be rendered")
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ),
            "No bitmap for \(size)"
        )
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(rendered, in: CGRect(origin: .zero, size: size))
        let opaqueImage = try XCTUnwrap(context.makeImage(), "The bitmap has no image")

        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil),
            "No PNG encoder"
        )
        CGImageDestinationAddImage(destination, opaqueImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "The page could not be encoded as PNG")
        return data as Data
    }
}
