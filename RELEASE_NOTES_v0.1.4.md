## Sideshot v0.1.4 — Annotation overhaul

This release is almost entirely about the annotation editor. It now has a complete, smooth, Preview-grade tool set.

### New tools
- **Ellipse / circle** (`O`) — ring the thing you're pointing at
- **Straight line** (`L`) — no arrowhead
- **Callout** (`C`) — drag from a label position to a target, type, and get a leader arrow
- **Black** swatch added (it was missing entirely)

### Feel
- **Dragging is smooth.** Drag state moved into each annotation view so the parent no longer re-renders on every frame; hover hit-testing is suppressed mid-drag; gesture runs in global coordinate space. Drags now track the cursor 1:1.
- **Snapping (magnetism).** Drop an annotation near the image center or an edge and it snaps to it.
- **Adjustable stroke width** — thin / medium / thick, applies to pen, line, arrow, rect and ellipse.

### Behaviour fixes
- **Delete key** removes the selected annotation (Fn+Delete too). Won't fire while you're typing in a text or callout box. Recoverable via Redo.
- **Save is always enabled** — no more grayed-out Save when you open a screenshot with no annotations yet. Saves the original image if you haven't drawn anything.
- **Cancel button removed** — close the window (or press Esc) like any normal window.
- **Tool shortcuts fixed** — `L`, `O` and `C` were never wired to the key handler.

### Install
Download `Sideshot-v0.1.4.zip` below, unzip, drag **Sideshot.app** to `/Applications`, right-click → Open once, and grant Screen Recording.

> Screen Recording permission must be re-granted after installing a new build — that's macOS, not Sideshot.

### Full annotation set
`V` select · `A` arrow · `L` line · `R` rectangle · `O` ellipse · `H` highlight · `P` pen · `T` text · `C` callout · `B` blur/redact
