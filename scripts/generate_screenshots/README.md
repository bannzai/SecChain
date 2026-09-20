# App Store screenshots

The seven screenshots of the iOS app, in English and Japanese, for iPhone 6.9 inch and iPad 13 inch
(issue #46). Each one is a whole picture built in SwiftUI — background, copy, and the subject the
copy argues about — and the subject of five of them is a capture of the running app.

```sh
make screenshots                                   # everything, into fastlane/screenshots
bash scripts/generate_screenshots/generate_appstore_screenshots.sh iphone69   # one device class
```

Nothing reaches `fastlane/screenshots` until the generated files pass the checks below.

## What runs

| Step | Script |
| --- | --- |
| Per language: boot the simulator of the device class in that language, fix its status bar and appearance, run the capture target | `capture_appstore_screenshots.sh <device class>` |
| Take the pages out of the result bundles and name them `artifacts/<device class>/<language>/<device class>-<page>.png` | `organize_appstore_screenshots.sh <device class>` |
| Check pixel size, alpha channel, and page count | `verify_appstore_screenshots.sh <directory> <device class> [...]` |
| All of it, for every device class, then copy into `fastlane/screenshots/<language>/` | `generate_appstore_screenshots.sh [device class ...]` |

The values every script shares — the device classes, their simulators and required pixel sizes, the
languages, and the page count — are in `screenshot_environment.sh`.

`artifacts/` is not tracked; what is delivered lives in `fastlane/screenshots/`.

## Where the pictures come from

`AppStoreScreenshotsUITests` is a UI test target that is not part of any app build. A run captures
the language `SCREENSHOT_LANGUAGE` names, because the status bar in the picture belongs to the
simulator and a simulator is in one language at a time.

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

After a change, generate again and look at every image, in both languages and on both device
classes, before delivering it.
