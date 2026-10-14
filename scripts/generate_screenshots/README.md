# App Store screenshots

The seven screenshots of the iOS app, in English and Japanese, for iPhone 6.9 inch and iPad 13 inch
(issue #46), and for the outer and the inner display of iPhone Duo (issue #87). Each one is a whole
picture built in SwiftUI — background, copy, and the subject the copy argues about — and the subject
of five of them is a capture of the running app.

```sh
make screenshots                                   # iPhone and iPad, into fastlane/screenshots
make screenshots-iphone-duo                        # both displays of iPhone Duo, into fastlane/screenshots_iphone_duo
bash scripts/generate_screenshots/generate_appstore_screenshots.sh iphone69   # one device class
```

Nothing reaches a delivery directory until the generated files pass the checks below.

## What runs

| Step | Script |
| --- | --- |
| Per language: boot the simulator of the device class in that language, fix its status bar and appearance, for iPhone Duo put it in the pose of the display, run the capture target | `capture_appstore_screenshots.sh <device class>` |
| Take the pages out of the result bundles and name them `artifacts/<device class>/<language>/<device class>-<page>.png` | `organize_appstore_screenshots.sh <device class>` |
| Check pixel size, alpha channel, and page count | `verify_appstore_screenshots.sh <directory> <device class> [...]` |
| All of it, for every device class asked for, then copy into the delivery directory of the class | `generate_appstore_screenshots.sh [device class ...]` |

The values every script shares — the device classes, their simulators, poses, required pixel sizes
and delivery directories, the languages, and the page count — are in `screenshot_environment.sh`.

`artifacts/` is not tracked; what is delivered lives in `fastlane/screenshots/` and
`fastlane/screenshots_iphone_duo/`.

## iPhone Duo

The outer display (`iphoneduo-outer`, 1398×2034) and the inner display (`iphoneduo-inner`,
2853×2007) are the one `iPhone Duo` simulator, which needs the iOS 27.1 runtime. Which display is on
depends on the pose, and only the window of the Device Hub can change the pose, so the capture
script switches it through `duo-pose.sh` of the `ios-simulator` skill of castle
(`SCREENSHOT_DUO_POSE_SCRIPT`, default `~/.agents/skills/ios-simulator/scripts/duo-pose.sh`). That
works on a Mac whose terminal has accessibility access and not on a remote simulator. The inner
display is delivered in landscape because the open device turns to landscape on its own.

Their pages go to `fastlane/screenshots_iphone_duo/<language>/` and not to `fastlane/screenshots/`:
`deliver` decides the display class of a picture from its pixel size, has no entry for the sizes of
iPhone Duo, and fails the whole upload on the first one it meets (fastlane 2.241.0,
`deliver/lib/deliver/app_screenshot.rb` and `app_screenshot_validator.rb`). They are uploaded
separately, into the one iPhone Duo entry of a version's screenshots in App Store Connect, which
holds the outer and the inner display together: the screenshot specification lists both under one
iPhone Duo heading and allows up to ten screenshots per device size
(https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications),
and the App Store Connect API names the entry `APP_IPHONE_DUO` and showed outer pictures uploaded
through it in the Duo entry of the web page
(https://github.com/rorkai/App-Store-Connect-CLI/pull/2926). Whether that limit counts the two
displays together, and whether the server accepts inner pictures, is not written anywhere we found
and was not tried here, so upload the outer pages first and the inner pages after them, and keep
the pages that matter most when the entry stops taking more. By hand: open the version in App Store
Connect, go to the iPhone Duo entry of the screenshots, and drop the files of one language from
`fastlane/screenshots_iphone_duo/<language>/` into it (the order of the files is the order on the
product page). From the command line, `asc` 5.12.0 or later uploads the same directory:

```sh
asc screenshots upload --version-localization <localization id> --path fastlane/screenshots_iphone_duo/<language> --device-type APP_IPHONE_DUO --skip-existing
```

From April 2027 the specification page requires these screenshots of every app built with the
iOS 27.1 SDK or later.

## Where the pictures come from

`AppStoreScreenshotsUITests` is a UI test target that is not part of any app build. A run captures
the language `SCREENSHOT_LANGUAGE` names, because the status bar in the picture belongs to the
simulator and a simulator is in one language at a time, and it composes the pages for the device
class `SCREENSHOT_DEVICE` names, which it checks against the window of the app it launched when the
class is one display of iPhone Duo.

| File | Holds |
| --- | --- |
| `AppStoreScreenshotUITest.swift` | Walks the app to the screens the pages need, composes each page, and attaches it as a PNG |
| `AppStoreScreenshotPages.swift` | Which subject each of the seven pages shows, and the text of the two drawn terminals |
| `AppStoreScreenshotLayout.swift` | The canvas: its size per device class, the background, the copy block, and the device mock |
| `AppStoreScreenshotTerminal.swift` | The terminal window drawn for the two pages whose subject is the Mac |
| `AppStoreScreenshotCopy.xcstrings` | The title and subtitle of every page, in English and Japanese |

The copy is in the test target's own String Catalog and not in the app's: it is never shown by the
app, and `make check-localization` fails on a key of the app's catalog that the code does not use.

Everything the app shows in a screenshot comes from its debug demo data (`AppModel.useDemoStore`,
`RemoteApprovalModel.useDemoData`): dummy values under example repositories, so no secret value, no
real public key, and nothing personal can end up in a picture.

## Changing a screenshot

- Copy: edit `AppStoreScreenshotCopy.xcstrings`, keeping both languages.
- What a page shows: edit `appStoreScreenshotPage` in `AppStoreScreenshotPages.swift`. Use a screen
  the app really has; if a page needs a screen no other page uses, add it to
  `AppStoreScreenshotScreen` and walk to it in `capturedScreens`.
- Sizes and spacing: `AppStoreScreenshotDevice` in `AppStoreScreenshotLayout.swift`. `canvasSize` is
  what App Store Connect requires and what `verify_appstore_screenshots.sh` checks, so it changes
  only together with `screenshot_expected_size` in `screenshot_environment.sh`.

After a change, generate again and look at every image, in both languages and on every device
class, before delivering it.
