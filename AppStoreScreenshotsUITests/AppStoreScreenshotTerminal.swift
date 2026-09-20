import SwiftUI

/// One line of the drawn terminal or editor panel, with the role that decides its color.
struct AppStoreScreenshotTerminalLine {
    /// What the line is, which is what its color says.
    enum Role {
        /// The command the user types, drawn after a prompt sign.
        case command
        /// Output of the command.
        case output
        /// A name or a path above a block, drawn like a file header.
        case header
        /// The refusal of the hook, drawn in the color of a warning.
        case denial
        /// Nothing, used for vertical space between blocks.
        case blank
    }

    let role: Role
    let text: String

    static func command(_ text: String) -> Self {
        Self(role: .command, text: text)
    }

    static func output(_ text: String) -> Self {
        Self(role: .output, text: text)
    }

    static func header(_ text: String) -> Self {
        Self(role: .header, text: text)
    }

    static func denial(_ text: String) -> Self {
        Self(role: .denial, text: text)
    }

    static let blank = Self(role: .blank, text: " ")
}

/// A terminal window drawn in place of a device mock, for the two screenshots whose subject is the
/// Mac rather than an app screen (issue #46, pages 4 and 5).
///
/// It is drawn rather than captured because the command-line tool has no screen to capture, and
/// because a capture of a real terminal would carry the user name and the window's surroundings.
struct AppStoreScreenshotTerminal: View {
    let device: AppStoreScreenshotDevice
    /// Name shown in the window's title bar.
    let title: String
    let lines: [AppStoreScreenshotTerminalLine]

    /// As large as the panel allows, because the App Store's preview is the size most people see a
    /// screenshot at. The limit is the longest line of `claudeHooksTerminalLines`, which no line
    /// may wrap at: it measured 960px wide on the iPhone at 38 and 1162px on the iPad at 46, and
    /// the horizontal padding is a full character on each side, so the panel's own width caps the
    /// size at 38.8 for the 1060px iPhone panel and at 68.9 for the 1880px iPad one.
    var fontSize: CGFloat {
        switch device {
        case .iPhone: 38
        case .iPad: 66
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: fontSize * 0.42) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineText(line: line)
                }
            }
            .font(.system(size: fontSize, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, fontSize)
            .padding(.vertical, fontSize * 1.1)
        }
        .background(
            RoundedRectangle(cornerRadius: device.screenCornerRadius * 0.4)
                .fill(Color(white: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: device.screenCornerRadius * 0.4)
                        .strokeBorder(Color(white: 0.28), lineWidth: 3)
                )
        )
    }

    var titleBar: some View {
        HStack(spacing: fontSize * 0.4) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.description) { color in
                Circle()
                    .fill(color)
                    .frame(width: fontSize * 0.45, height: fontSize * 0.45)
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: fontSize * 0.72, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.62))
            Spacer(minLength: 0)
            // Keeps the title centered against the three circles on the left.
            Color.clear
                .frame(width: fontSize * 2.15, height: fontSize * 0.45)
        }
        .padding(.horizontal, fontSize * 0.7)
        .padding(.vertical, fontSize * 0.55)
        .background(Color(white: 0.14))
    }

    @ViewBuilder
    func lineText(line: AppStoreScreenshotTerminalLine) -> some View {
        switch line.role {
        case .command:
            HStack(spacing: 0) {
                Text(verbatim: "$ ").foregroundStyle(Color(red: 0.42, green: 0.85, blue: 0.55))
                Text(verbatim: line.text).foregroundStyle(.white)
            }
        case .output:
            Text(verbatim: line.text).foregroundStyle(Color(white: 0.68))
        case .header:
            Text(verbatim: line.text).foregroundStyle(Color(red: 0.55, green: 0.72, blue: 1))
        case .denial:
            Text(verbatim: line.text).foregroundStyle(Color(red: 1, green: 0.65, blue: 0.3))
        case .blank:
            Text(verbatim: " ")
        }
    }
}
