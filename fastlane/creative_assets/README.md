# App Store creative assets

The product page header and the search results asset of the iOS app (issue #54). Both are
optional App Store assets shown on iOS 27 and later, separate from the screenshots in
`fastlane/screenshots`.

| File | Placement | Canvas | Art Safe Area (left, top, right, bottom) |
| --- | --- | --- | --- |
| `product_page_header.png` | Top of the product page | 3840 x 1646 | 1097, 493, 2743, 1154 |
| `search_results.png` | Search results | 3840 x 2560 | 836, 765, 3004, 1795 |

The canvas and the safe area come from Apple's official templates
(https://developer.apple.com/app-store/asset-best-practices/). Apple crops the canvas differently
per device, so everything that carries the idea sits inside the safe area and the rest is
decoration. Both files pass `check_header_asset.sh` of the `appstore-header-creative` skill.

## The one idea

Three links of a chain are circles, and each circle holds one key: every secret of a project is
kept in its own link of the chain. It reuses the two motifs of the app icon (a key and a chain) on
the icon's background color, so the header, the search results asset, and the icon read as one
app. The assets carry no text, so one file serves every language.

## How they were made

Generated with the `gemini-image-generator` skill (Nano Banana Pro, `gemini-3-pro-image-preview`,
4K, 2026-09-23), then normalized to the canvas with `normalize_asset.sh` and checked with
`check_header_asset.sh`. The generator returns JPEG data; the files here are re-encoded as PNG.

Header prompt (aspect ratio 21:9):

> Flat vector illustration, crisp clean edges, uniform white stroke, no glow, no blur, no grain,
> no texture, no gradient, no text, no letters. A solid #27245D deep navy background fills every
> pixel of the image including all four corners and edges; no frame, no border, no rounded tile,
> no white margin. Subject: a thin horizontal chain crossing the image from left to right at the
> vertical center. Three consecutive links at the center of the chain are perfect circles of the
> same size, connected to each other in a row, and inside each circle sits one classic key exactly
> like the standard key icon (round bow, straight shaft, two rectangular teeth), drawn as a thick
> white outline, horizontal, one key per circle. The three circles with their keys together fit
> inside the central 40 percent of the width and 32 percent of the height of the image. The
> ordinary rounded rectangular links to the left and right become thinner and fade into the navy
> background near the edges. Wide cinematic composition, mostly empty navy space above and below.

Search results prompt (aspect ratio 3:2): the same text with "The circles are small: the three
circles with their keys together fit inside the central 38 percent of the width and 22 percent of
the height of the image." and "Landscape composition" in place of the size sentence and "Wide
cinematic composition". A first attempt at 50 percent of the width put the outer circles across
the safe area edge.

## Candidates that were not adopted

- A key and a chain drawn across the whole canvas (2026-09-18): the chain was a horizontal line
  over the full width, only the key sat inside the safe area, and the key's tip crossed the top
  edge of the safe area. The maintainer judged it weak.
- An `.env` file dissolving into a padlock (2026-09-18): the padlock is not a motif of the icon,
  and the file and the key sat outside the safe area, so small devices showed only a generic
  padlock.
- One key hanging from the chain by its bow, and one key inside a single circular link
  (2026-09-23): both fit the safe area, but the maintainer preferred several keys, one per link.
- Five keys hanging vertically from the chain (2026-09-23): the tips of the keys crossed the
  bottom edge of the safe area, and the generator drew a second, blurred chain above.

## Submitting

App Store Connect accepts creative assets through the Asset Library or attached to an app
version. The iOS app record does not exist yet, so the submission is an item of the maintainer's
task list (issue #16).
