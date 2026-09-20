import Foundation

/// The marketing copy of one screenshot, in the language being captured.
///
/// The texts live in this target's `AppStoreScreenshotCopy.xcstrings` and not in the app's String
/// Catalog: they are never shown by the app, and `make check-localization` covers the app's catalog
/// alone, where an unused key is a failure (issue #46).
struct AppStoreScreenshotCopy {
    /// Headline of the screenshot.
    let title: String
    /// Line below the headline.
    let subtitle: String
}

/// Anchor for `Bundle(for:)`. A bundle can only be found from a class, and the copy has to be read
/// from the test bundle rather than from the main bundle, which belongs to the test runner app.
private final class AppStoreScreenshotCopyBundle {}

/// The copy of one page in one language.
///
/// The language is a parameter instead of the process's own language: one test run captures every
/// language, and relaunching the test runner in another language is not possible.
func appStoreScreenshotCopy(pageNumber: Int, language: String) -> AppStoreScreenshotCopy {
    AppStoreScreenshotCopy(
        title: appStoreScreenshotCopyText(key: "page\(pageNumber).title", language: language),
        subtitle: appStoreScreenshotCopyText(key: "page\(pageNumber).subtitle", language: language)
    )
}

/// The text of one key, or the key itself when the catalog has no entry for it, which is what
/// `localizedString` returns and what the test asserts on.
func appStoreScreenshotCopyText(key: String, language: String) -> String {
    appStoreScreenshotCopyLanguageBundle(language: language)
        .localizedString(forKey: key, value: nil, table: "AppStoreScreenshotCopy")
}

private func appStoreScreenshotCopyLanguageBundle(language: String) -> Bundle {
    let testBundle = Bundle(for: AppStoreScreenshotCopyBundle.self)
    guard let languageBundlePath = testBundle.path(forResource: language, ofType: "lproj"),
          let languageBundle = Bundle(path: languageBundlePath) else {
        return testBundle
    }
    return languageBundle
}
