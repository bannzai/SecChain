import SwiftUI
import UIKit

/// The device class one set of screenshots is made for, with the pixel size App Store Connect
/// requires for it and the measurements of the layout at that size.
///
/// The canvas is rendered at scale 1, so one point of this layout is one pixel of the delivered
/// image and the sizes below are pixels.
enum AppStoreScreenshotDevice: CaseIterable {
    /// iPhone 6.9 inch.
    case iPhone
    /// iPad 13 inch.
    case iPad
    /// The outer display of iPhone Duo, the one that is on while the device is closed (issue #87).
    case iPhoneDuoOuter
    /// The inner display of iPhone Duo, the one that is on while the device is open. Delivered in
    /// landscape, because that is the orientation the open device takes on its own, so a capture
    /// needs no rotation of the device (`appstore-screenshot-builder`, `references/iphone-duo.md`).
    case iPhoneDuoInner

    /// The device class the simulator the test is running on belongs to, read from the simulator
    /// itself so that no argument can put an iPad layout on an iPhone image.
    ///
    /// The two displays of iPhone Duo cannot be told apart this way: both answer `.phone`, and the
    /// display that is on depends on the pose the capture script put the device in. The script
    /// names the class in `SCREENSHOT_DEVICE`, and the test checks it against the window of the
    /// app it launched (`expectedAppWindowSize`).
    @MainActor
    static var current: AppStoreScreenshotDevice {
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    }

    /// The size App Store Connect accepts for this device class, which is also the native size of
    /// the display the capture runs on (iPhone 17 Pro Max, iPad Pro 13-inch, and the two displays
    /// of iPhone Duo).
    var canvasSize: CGSize {
        switch self {
        case .iPhone: CGSize(width: 1320, height: 2868)
        case .iPad: CGSize(width: 2064, height: 2752)
        case .iPhoneDuoOuter: CGSize(width: 1398, height: 2034)
        case .iPhoneDuoInner: CGSize(width: 2853, height: 2007)
        }
    }

    /// Name of this device class in a file name, which is how the generation script tells the
    /// sets apart in one output directory and names the class in `SCREENSHOT_DEVICE`.
    var fileNameComponent: String {
        switch self {
        case .iPhone: "iphone69"
        case .iPad: "ipad13"
        case .iPhoneDuoOuter: "iphoneduo-outer"
        case .iPhoneDuoInner: "iphoneduo-inner"
        }
    }

    /// The size of the app's window in points on the display this class is captured from, for the
    /// classes whose display is chosen by a pose the capture script sets rather than by the
    /// simulator. The test refuses to compose a page when the window it launched has another size,
    /// because a page composed in the wrong pose would carry the other display's capture. The other
    /// classes have no expectation: their simulator has one display, and the layout follows it.
    var expectedAppWindowSize: CGSize? {
        switch self {
        case .iPhone, .iPad: nil
        // 1398x2034 and 2853x2007 pixels at 3x.
        case .iPhoneDuoOuter: CGSize(width: 466, height: 678)
        case .iPhoneDuoInner: CGSize(width: 951, height: 669)
        }
    }

    /// Whether the page is wider than tall, which puts the copy beside the subject instead of
    /// above it.
    var isLandscape: Bool {
        canvasSize.width > canvasSize.height
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .iPhone: 110
        case .iPad: 180
        case .iPhoneDuoOuter: 100
        case .iPhoneDuoInner: 140
        }
    }

    var topPadding: CGFloat {
        switch self {
        case .iPhone: 170
        case .iPad: 210
        case .iPhoneDuoOuter: 150
        case .iPhoneDuoInner: 0
        }
    }

    /// Width of the copy on a landscape page, where it is a column on the left. Wide enough for
    /// the longest single line of a title, "AI エージェントの実行も", at `titleFontSize`.
    var copyColumnWidth: CGFloat {
        switch self {
        case .iPhone, .iPad, .iPhoneDuoOuter: canvasSize.width - 2 * horizontalPadding
        case .iPhoneDuoInner: 1120
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .iPhone: 92
        case .iPad: 108
        case .iPhoneDuoOuter, .iPhoneDuoInner: 88
        }
    }

    var subtitleFontSize: CGFloat {
        switch self {
        case .iPhone: 50
        case .iPad: 58
        case .iPhoneDuoOuter: 48
        case .iPhoneDuoInner: 50
        }
    }

    var copySpacing: CGFloat {
        switch self {
        case .iPhone: 30
        case .iPad: 34
        case .iPhoneDuoOuter: 28
        case .iPhoneDuoInner: 32
        }
    }

    /// Where the device mock or the terminal starts on a portrait page. Fixed rather than derived
    /// from the height of the copy so that the mock sits at the same height in every language.
    ///
    /// Far enough below the copy that the longest one still breathes: the iPad's copy reaches row
    /// 630 when both the title and the subtitle take two lines, which is the fourth and the fifth
    /// page, and a subject starting at 640 read as stuck to it. On a landscape page the subject is
    /// centered vertically instead, and this is unused.
    var subjectTop: CGFloat {
        switch self {
        case .iPhone: 660
        case .iPad: 720
        case .iPhoneDuoOuter: 620
        case .iPhoneDuoInner: 0
        }
    }

    /// Where the subject starts on a landscape page: right of the copy column, with a gap that
    /// keeps the two apart.
    var subjectLeft: CGFloat {
        horizontalPadding + copyColumnWidth + 80
    }

    /// Outer width of the device mock and of the terminal. Close to the canvas on the iPad, whose
    /// screen puts a sidebar and a detail column side by side and would otherwise be unreadable at
    /// the size a product page shows a screenshot at. The inner display of iPhone Duo shows the
    /// same two columns, so its mock takes the width left of the copy column and runs past the
    /// right edge, the way a portrait mock runs past the bottom.
    var subjectWidth: CGFloat {
        switch self {
        case .iPhone: 1060
        case .iPad: 1880
        case .iPhoneDuoOuter: 1100
        case .iPhoneDuoInner: 1660
        }
    }

    /// Thickness of the mock's bezel around the captured screen.
    var bezelWidth: CGFloat {
        switch self {
        case .iPhone, .iPhoneDuoOuter, .iPhoneDuoInner: 22
        case .iPad: 26
        }
    }

    /// Corner radius of the captured screen inside the mock, close to the radius of the real
    /// display so that the mock does not read as a rectangle with rounded corners.
    var screenCornerRadius: CGFloat {
        switch self {
        case .iPhone, .iPhoneDuoOuter: 96
        case .iPad: 60
        case .iPhoneDuoInner: 80
        }
    }
}

/// One finished screenshot: the background, the copy, and the subject below it, or beside it on a
/// landscape page.
///
/// On a portrait page every subject starts at `subjectTop`, so the seven pages line up when they
/// are read one after the other. A device mock is taller than the space left there and runs past
/// the bottom edge, which is the layout the skill describes (`appstore-screenshot-builder`): the
/// eye goes from the copy into a screen that continues beyond the image. On a landscape page the
/// copy is a column on the left and the subject sits centered beside it, running past the right
/// edge.
struct AppStoreScreenshotLayout<Subject: View>: View {
    let device: AppStoreScreenshotDevice
    let copy: AppStoreScreenshotCopy
    @ViewBuilder let subject: () -> Subject

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The app icon's navy, fading into black towards the bottom, so that the cut-off mock
            // meets a dark edge instead of a visible seam.
            LinearGradient(
                colors: [Color(red: 0x26 / 255, green: 0x23 / 255, blue: 0x5C / 255), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: device.canvasSize.width, height: device.canvasSize.height)
            if device.isLandscape {
                copyBlock
                    .frame(width: device.copyColumnWidth)
                    .frame(height: device.canvasSize.height, alignment: .center)
                    .offset(x: device.horizontalPadding)
                subject()
                    .frame(width: device.subjectWidth)
                    .frame(height: device.canvasSize.height, alignment: .center)
                    .offset(x: device.subjectLeft)
            } else {
                copyBlock
                    .frame(width: device.copyColumnWidth, alignment: .top)
                    .offset(x: device.horizontalPadding, y: device.topPadding)
                subject()
                    .frame(width: device.subjectWidth)
                    .frame(height: device.canvasSize.height - device.subjectTop, alignment: .top)
                    .offset(x: (device.canvasSize.width - device.subjectWidth) / 2, y: device.subjectTop)
            }
        }
        .frame(width: device.canvasSize.width, height: device.canvasSize.height, alignment: .topLeading)
        .background(Color.black)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// Centered over the subject on a portrait page, left-aligned in its column on a landscape
    /// one, where the subject is beside it rather than under it.
    var copyBlock: some View {
        VStack(alignment: device.isLandscape ? .leading : .center, spacing: device.copySpacing) {
            Text(copy.title)
                .font(.system(size: device.titleFontSize, weight: .bold))
                .foregroundStyle(.white)
            Text(copy.subtitle)
                .font(.system(size: device.subtitleFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .multilineTextAlignment(device.isLandscape ? .leading : .center)
        .frame(maxWidth: .infinity, alignment: device.isLandscape ? .leading : .center)
    }
}

/// A capture of the running app inside a drawn device mock.
///
/// The frame is drawn instead of composited from an image file, so that nothing but the app's own
/// screen is a bitmap.
struct AppStoreScreenshotDeviceMock: View {
    let device: AppStoreScreenshotDevice
    /// The screen of the app as the simulator rendered it.
    let capture: UIImage

    var body: some View {
        Image(uiImage: capture)
            .resizable()
            .frame(width: screenSize.width, height: screenSize.height)
            .clipShape(RoundedRectangle(cornerRadius: device.screenCornerRadius))
            .padding(device.bezelWidth)
            .background(
                RoundedRectangle(cornerRadius: device.screenCornerRadius + device.bezelWidth)
                    .fill(Color(white: 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: device.screenCornerRadius + device.bezelWidth)
                            .strokeBorder(Color(white: 0.34), lineWidth: 4)
                    )
            )
    }

    /// The capture keeps its aspect ratio inside the mock, so a capture that is not the native size
    /// of the device class is scaled rather than distorted.
    var screenSize: CGSize {
        let width = device.subjectWidth - 2 * device.bezelWidth
        return CGSize(width: width, height: width * capture.size.height / capture.size.width)
    }
}
