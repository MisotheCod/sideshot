# Sideshot

**Every screenshot tool gets the capture right. The annoying part is everything after it.**

On macOS, `⌘⇧4` takes the picture and then abandons you. A thumbnail blinks in the corner and disappears before you decide what to do with it. The file lands on your Desktop under a name you didn't pick. To actually *send* that screenshot you have to find it, open it, mark it up in another app, save it again, then drag it out of a folder.

Sideshot fixes the middle part. A capture doesn't become a file you have to hunt for — it becomes a card stacked on the edge of your screen, waiting for you to decide: copy it, save it, drag it out, annotate it, or throw it away. Nothing touches your Desktop unless you say so.

<p align="center">
  <a href="docs/sideshot-promo.mp4"><img src="docs/sideshot-promo.webp" alt="Sideshot — capture, copy straight from the side stack, then annotate" width="100%"></a>
</p>

<p align="center"><sub><a href="docs/sideshot-promo.mp4">▶ Watch the 38s promo with sound</a></sub></p>

## What it actually solves

| The thing that's annoying | What Sideshot does instead |
|---|---|
| The floating thumbnail vanishes before you've decided what to do with it | Captures wait in a stack on the edge of the screen until *you* act on them |
| Every screenshot becomes another file cluttering your Desktop | Nothing is saved unless you choose to save it |
| Sending one means a round trip through Finder and Preview | Hover the card, hit **Copy** — it's on your clipboard and the card slides away |
| Marking something up means opening a second app and losing the capture | Annotations are built in: arrows, callouts, text, highlight, blur |
| Sensitive details (a customer, an amount, a token) leak before you notice | Blur and redact in place, before it ever leaves the app |
| Screen recording lands a file on your Desktop that you still have to trim | Recordings stop into the stack as unsaved cards, and trim right there |
| Copying text out of a screenshot means retyping it | Live Text reads the image — select and copy the words, or click a link |

## Features

- **Menu-bar app** — no Dock icon; lives in the status bar.
- **Global hotkeys**
  - `⌘⇧4` — capture an area (drag a clean rectangle, no crosshairs)
  - `⌘⇧3` — capture the full screen
  - `⌘⇧5` — record (screen / window / area)
  - `Esc` — cancel any in-progress capture or recording
- **Window capture** — every window dims, the one under your cursor lights up, click to snap it.
- **Floating side stack** — results stack on the screen edge (newest at the bottom). Hover to **Copy** or **Save**; drag a card out to export it anywhere; double-click for a full preview.
- **Annotate** — double-click any screenshot to mark it up before sharing: selector, arrow, line, rectangle, ellipse, highlighter, freehand pen, text, **callout** (label + leader arrow), and blur (for redacting sensitive bits). Adjustable colors and three stroke widths, drag-to-move with snapping to the image centre and edges, corner resize handles, delete key, undo/redo, and live pixelation.
- **Live Text** — the screenshot is read with Vision, so you can select and copy text straight out of the image, and click links to open them.
- **Recording** — stops into the stack as an unsaved card (nothing is saved until you say so).
- **QuickTime-style editor** — scrub and trim recordings on one strip, then **Save As…**.
- **Naming** — `SS_MMMddyy_HH.mm.png` / `SR_MMMddyy_HH.mm.mov` (e.g. `SS_Oct1826_13.05.png`), with a `_2` suffix on collisions.
- **Choose your save location** from the menu bar.

## Privacy

No telemetry, no accounts, no cloud. Captures never leave your Mac — text recognition and OCR run on-device through Apple's Vision framework.

Built with **ScreenCaptureKit**, native SwiftUI/AppKit, and Carbon global hotkeys.

## Download

**[Download the latest release](../../releases/latest)** — unzip, then drag **Sideshot.app** into `/Applications`.

Requires **macOS 14 (Sonoma) or later**. Universal build, Apple silicon and Intel.

**Sideshot updates itself.** It checks for a new version once a day and, when there is one, adds a row at the top of its menu: *Sideshot x.y.z is available…*. No re-downloading, no update dialog to miss — everything is EdDSA-signed by [Sparkle](https://sparkle-project.org) and verified before it installs. **Check for Updates…** in the menu forces a check.

> Because the builds are locally signed (not Apple-notarized), macOS Gatekeeper complains on first launch: **right-click → Open**, then confirm. Then grant **Screen Recording** in *System Settings → Privacy & Security → Screen and System Audio Recording* — required for capture and recording. If you ever need to revoke it, quit Sideshot first, otherwise macOS may leave the entry in place.

## Releasing

`./release.sh "notes"` builds, signs the archive, writes `appcast.xml` and cuts the GitHub release. Every release must carry `appcast.xml` as an asset — the app polls `releases/latest/download/appcast.xml`, so a release without it is a 404 for every installed copy.

## Build from source

```bash
# 1. Install xcodegen
brew install xcodegen

# 2. Generate the Xcode project
xcodegen generate

# 3. Build
xcodebuild -project Sideshot.xcodeproj -scheme Sideshot -configuration Release build
```

Requires macOS 14+ and Xcode 15+.

## License

[MIT](./LICENSE)
