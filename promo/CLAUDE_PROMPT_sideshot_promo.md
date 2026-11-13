# Prompt: make a promo video for Sideshot

You are making a short product promo video for **Sideshot**, a free, open-source macOS screenshot and screen-recording app. Produce a finished, polished MP4 I can post publicly. Work until the file exists and is verified — do not stop at a plan or a storyboard.

---

## 1. The product (do not invent features)

Sideshot is a menu-bar Mac app I built because macOS's built-in screenshot UI is annoying. Its differentiator is **where screenshots go**:

- Press **⌘⇧4** (area), **⌘⇧3** (fullscreen), or **⌘⇧5** (record). Capture is instant and non-blocking.
- Screenshots **do not vanish into a corner preview**. They land as **live cards stacked down the left edge of the screen** and stay there.
- Each card, on hover, reveals **Copy** and **Save**. After either action the card **slides off the left edge**.
- **Drag a card out** of the stack and it's removed. **Double-click** a card for a large preview.
- Double-click **opens a full annotation editor** with: selector, arrow, line, rectangle, ellipse, highlighter, pen, text, **callout** (text + leader arrow), and **blur/redact**. Adjustable colors (including black) and three stroke widths. Drag-to-move with snapping to image center/edges, resize handles, delete key, undo/redo.
- **Live Text**: the screenshot is OCR'd, so you can select and copy text straight out of the image, and click links to open them.
- Recordings capture to MP4 and **do not auto-save** — they stop into the stack as an unsaved card you trim in a QuickTime-style filmstrip editor.
- Screenshots exclude Sideshot's own floating UI.
- It's free and open source: `github.com/MisotheCod/sideshot`.

**Hard rule: never render fake product UI.** Any Sideshot screen you show must be a faithful reproduction of the real app (build it in HTML/CSS to the spec below, or composite the real screenshot asset). Do not ask an image/video model to imagine the interface — it will hallucinate buttons and numbers, and that has burned me before.

---

## 2. Deliverable

| Spec | Value |
|---|---|
| File | `sideshot-promo-1080p.mp4` |
| Resolution | 1920×1080 |
| Frame rate | 30 fps |
| Length | 30–40 seconds |
| Codec | H.264, yuv420p, `+faststart` |
| Audio | A quiet music bed is welcome. No voiceover. If you can't source licensed music, ship it silent rather than with a bad track. |
| Safe areas | Keep all text at least 90px from every edge |
| Text size | Nothing below 28px |

---

## 3. Brand

Sample these from the real app icon (`icon_512x512@2x.png`, 1024×1024):

| Token | Value | Use |
|---|---|---|
| Ground | `#07080B` | Page background |
| Panel | `#101319` / `#171B23` | Windows, cards |
| Hairline | `#232833` | Borders |
| Ink | `#F6F8FB` | Primary text |
| Muted | `#8D94A5` | Secondary text |
| Accent | `#366AE1` | Primary blue |
| Accent light | `#5AA0F5` | Glows, highlights |

- Font: system stack — `-apple-system, "SF Pro Display", "Helvetica Neue", Arial, sans-serif`. Weight 600–700 for titles, 450–500 for body. Tracking tight on big type (`-0.04em`).
- The icon has a dark ground with a blue mark — put a soft blue glow *behind* it, never on top.
- Whole film reads dark and high-contrast. No white backgrounds except the annotation canvas (which is meant to look like a real light-mode screenshot).

---

## 4. Storyboard (target ~34s)

Keep each beat under 3 seconds of stillness. Every cut should be motivated by the previous gesture.

**0:00–0:05 — Hook.**
Dark ground, soft blue glow blooms. The app icon scales up out of a blur. Wordmark "Sideshot" rises under it. Tagline fades in: **"Screenshots that stay out of your way."** Slow push-in on the whole group.
*Frame 0 must already have the icon and wordmark visible* — this frame is the thumbnail everywhere it's posted.

**0:05–0:13 — The capture.**
A mock macOS window (dark, traffic-light dots, skeleton text lines) fades up on a subtle radial background. The keycaps **⌘ ⇧ 4** pop in one at a time with a springy overshoot. A dashed blue marquee sweeps across the window. A white flash. A card pops out of the capture area and **flies to the left edge, shrinking** to its resting size.
Caption: **"Press ⌘⇧4 — and it's already captured."**

**0:13–0:20 — The stack (the whole point).**
Three cards are now stacked down the left edge, staggering in. Caption: **"It doesn't vanish. It waits on the side."**
Hover the middle card: **Copy** and **Save** pills fade in and the card lifts slightly. Click Copy → the pills fade out, a green **✓** appears, then the card **slides off the left edge**. The stack closes the gap.

**0:20–0:28 — Annotate.**
The annotation editor fades up: a dark header bar with a row of tool glyphs (pointer, arrow, line, rectangle, ellipse, highlighter, pen, text, callout, blur), a color row, three stroke-width capsules, and **Save** / **Copy** at the right. Below it, a light canvas with mock document text and a white panel containing a blue button.
Draw a **red arrow** onto the blue button (animate `stroke-dashoffset` so it draws itself, then the arrowhead snaps on). Then a **blue callout** box that scales in, reads **"fix this spacing"**, with a leader line that draws toward a gap in the text.
Caption: **"Annotate without opening another app."**

**0:28–0:34 — End card.**
Icon, "Sideshot", **"Free. Open source. Yours."**, then the URL in accent blue: `github.com/MisotheCod/sideshot`. Very slow scale so it never feels frozen.

---

## 5. Craft rules

- **Easing:** `power3.out` / `power4.out` for entrances, `power2.in` for exits. Nothing linear. Nothing bouncy except the keycaps.
- **Stagger** grouped elements by 0.08–0.12s.
- **Motion must be continuous** — never let the frame sit unchanged for more than ~3s.
- Every element enters *and* exits on screen; don't hard-cut a half-faded element.
- Animate **transforms** (`x`, `y`, `scale`, `opacity`, `filter`) — never `left`/`top`/`width`, which snap to integer pixels and stutter.
- Subtle film grain or a vignette is fine; heavy lens flare and stock "tech" swooshes are not.
- No drop shadows on text. No gradients on text. No emoji as icons.

---

## 6. Build it

Preferred tool: **HyperFrames** (`npx hyperframes init`, then author `index.html` with CSS + a seekable GSAP timeline registered on `window.__timelines`; `npx hyperframes check` then `render`). It gives deterministic, frame-perfect output and lets you author the UI yourself instead of prompting a model for it.

Scaffold:

```bash
npx hyperframes init sideshot-promo --non-interactive --resolution=landscape --skip-skills
cd sideshot-promo
# write index.html (composition), assets/logo.png
npx hyperframes check .          # must report 0 errors
npx hyperframes snapshot --at 1.5,7.5,10.5,16.5,24.5,31.5   # LOOK at the frames
npx hyperframes render . -o sideshot-promo-1080p.mp4 --format mp4 --fps 30 --quality delivery
```

Requirements if you use HyperFrames:
- Root: `<div data-composition-id="main" data-start="0" data-duration="34" data-width="1920" data-height="1080">`
- Each timed scene: `class="clip" data-start="<s>" data-duration="<s>"`
- One paused timeline: `window.__timelines["main"] = gsap.timeline({paused:true})`
- No `Date.now()`, no `Math.random()`, no network fetches.

Assets available: app icon at `Sideshot/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png` (1024×1024). Real UI screenshots at `docs/screenshots/editor.png` and `onboarding.png` (low-res — prefer rebuilding the UI in HTML for crispness at 1080p; use the screenshots only as reference for layout).

---

## 7. Verify before you say it's done

Do not report success off a clean lint alone. Actually look at the output:

1. `ffprobe` the file: 1920×1080, 30fps, ~34s, h264.
2. Extract at least 6 frames across the timeline (`ffmpeg -ss <t> -i file -frames:v 1`) and **view them**. Check: nothing clipped at edges, captions not overlapping windows, text legible at small size, frame 1 not empty, no half-faded element.
3. Confirm the icon and wordmark are visible in the first frame.
4. Report the absolute path of the final MP4.

---

## 8. Do not

- Do not show macOS's own screenshot UI, and do not imply Sideshot is a paid product.
- Do not invent stats, user counts, reviews, or awards. It's a personal open-source tool.
- Do not add a fake iOS version, fake pricing tiers, or a fake web app.
- Do not use an AI-generated presenter/avatar.
- Do not leave placeholder text ("Lorem ipsum", "Title goes here") in the final render.

When finished, return: the MP4 path, the ffprobe summary, and the frames you checked.
