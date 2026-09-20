import SwiftUI
import UIKit

/// The device class one set of screenshots is made for, with the pixel size App Store Connect
/// requires for it and the measurements of the layout at that size.
///
/// The canvas is rendered at scale 1, so one point of this layout is one pixel of the delivered
/// image and the sizes below are pixels.
enum AppStoreScreenshotDevice {
    /// iPhone 6.9 inch.
    case iPhone
    /// iPad 13 inch.
    case iPad

    /// The device the test is running on. The capture run picks the simulator; the layout follows
    /// it, so that no argument can put an iPad layout on an iPhone image.
    @MainActor
    static var current: AppStoreScreenshotDevice {
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    }

    /// The size App Store Connect accepts for this device class, which is also the native size of
    /// the simulator the capture runs on (iPhone 17 Pro Max, iPad Pro 13-inch).
    var canvasSize: CGSize {
        switch self {
        case .iPhone: CGSize(width: 1320, height: 2868)
        case .iPad: CGSize(width: 2064, height: 2752)
        }
    }

    /// Name of this device class in a file name, which is how the generation script tells the two
    /// sets apart in one output directory.
    var fileNameComponent: String {
        switch self {
        case .iPhone: "iphone69"
        case .iPad: "ipad13"
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .iPhone: 110
        case .iPad: 180
        }
    }

    var topPadding: CGFloat {
        switch self {
        case .iPhone: 170
        case .iPad: 210
        }
    }

    var titleFontSize: CGFloat {
        switch self {
        case .iPhone: 92
        case .iPad: 108
        }
    }

    var subtitleFontSize: CGFloat {
        switch self {
        case .iPhone: 50
        case .iPad: 58
        }
    }

    var copySpacing: CGFloat {
        switch self {
        case .iPhone: 30
        case .iPad: 34
        }
    }

    /// Where the device mock or the terminal starts. Fixed rather than derived from the height of
    /// the copy so that the mock sits at the same height in every language.
    ///
    /// Far enough below the copy that the longest one still breathes: the iPad's copy reaches row
    /// 630 when both the title and the subtitle take two lines, which is the fourth and the fifth
    /// page, and a subject starting at 640 read as stuck to it.
    var subjectTop: CGFloat {
        switch self {
        case .iPhone: 660
        case .iPad: 720
        }
    }

    /// Outer width of the device mock and of the terminal. Close to the canvas on the iPad, whose
    /// screen puts a sidebar and a detail column side by side and would otherwise be unreadable at
    /// the size a product page shows a screenshot at.
    var subjectWidth: CGFloat {
        switch self {
        case .iPhone: 1060
        case .iPad: 1880
        }
    }

    /// Thickness of the mock's bezel around the captured screen.
    var bezelWidth: CGFloat {
        switch self {
        case .iPhone: 22
        case .iPad: 26
        }
    }

    /// Corner radius of the captured screen inside the mock, close to the radius of the real
    /// display so that the mock does not read as a rectangle with rounded corners.
    var screenCornerRadius: CGFloat {
        switch self {
        case .iPhone: 96
        case .iPad: 60
        }
    }
}

/// One finished screenshot: the background, the copy, and the subject below it.
///
/// Every subject starts at `subjectTop`, so the seven pages line up when they are read one after
/// the other. A device mock is taller than the space left there and runs past the bottom edge,
/// which is the layout the skill describes (`appstore-screenshot-builder`): the eye goes from the
/// copy into a screen that continues beyond the image.
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
            copyBlock
                .frame(width: device.canvasSize.width - 2 * device.horizontalPadding, alignment: .top)
                .offset(x: device.horizontalPadding, y: device.topPadding)
            subject()
                .frame(width: device.subjectWidth)
                .frame(height: device.canvasSize.height - device.subjectTop, alignment: .top)
                .offset(x: (device.canvasSize.width - device.subjectWidth) / 2, y: device.subjectTop)
        }
        .frame(width: device.canvasSize.width, height: device.canvasSize.height, alignment: .topLeading)
        .background(Color.black)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    var copyBlock: some View {
        VStack(spacing: device.copySpacing) {
            Text(copy.title)
                .font(.system(size: device.titleFontSize, weight: .bold))
                .foregroundStyle(.white)
            Text(copy.subtitle)
                .font(.system(size: device.subtitleFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
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
