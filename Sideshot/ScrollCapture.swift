import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Full-page ("scrolling") capture of a single window.
///
/// The window is captured through `SCContentFilter(desktopIndependentWindow:)`, so it
/// works even when other windows overlap it. Between frames we post a scroll-wheel
/// event into the window, then work out how far the content actually moved by matching
/// the bottom of what we already have against the top of the new frame — that is what
/// makes the stitch line up regardless of scroll acceleration or smooth scrolling.
///
/// Posting scroll events to another application requires the Accessibility permission.
enum ScrollCaptureError: LocalizedError {
    case accessibilityDenied
    case noContent
    case framesDidNotMatch
    case tooTall(Int)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Sideshot needs Accessibility permission to scroll other windows. Grant it in System Settings → Privacy & Security → Accessibility."
        case .noContent:
            return "Couldn't read that window."
        case .framesDidNotMatch:
            return "Couldn't line up the frames while scrolling. Try again with a smaller window."
        case .tooTall(let px):
            return "That page is too long to stitch (over \(px) px)."
        }
    }
}

final class ScrollCapture {
    static let shared = ScrollCapture()
    private init() {}

    /// How much of the window we scroll past each step. The leftover is the overlap the
    /// matcher uses to align frames: too little and pages full of similar rows (file
    /// lists, tables) match the wrong band, which duplicates a chunk of the page. 0.6
    /// leaves ~40% of a viewport of context, which is enough to be unambiguous.
    private let scrollFraction: CGFloat = 0.6
    private let maxFrames = 120
    /// In device pixels. A Retina display doubles the point height, so the old 30k
    /// cap tripped on pages only ~15k points tall.
    private let maxHeight = 60_000
    /// Memory guard: the stitcher holds the whole image as RGBA.
    private let maxPixels = 200_000_000

    var isRunning = false

    // MARK: - Permission

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt once if we don't have Accessibility yet.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Run

    /// Captures `window` top to bottom. `progress` is called on the main queue with the
    /// stitched height so far.
    func capture(window: SCWindow,
                 screen: NSScreen,
                 progress: @escaping (Int) -> Void) async throws -> CGImage {
        guard !isRunning else { throw ScrollCaptureError.noContent }
        guard Self.hasAccessibility() else {
            Self.requestAccessibility()
            throw ScrollCaptureError.accessibilityDenied
        }
        isRunning = true
        defer { isRunning = false }

        raise(window: window)
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Preferred path: drive the real scroll bar to exact positions. This is the
        // native equivalent of GoFullPage's window.scrollTo — no smooth scrolling, no
        // rubber-banding, no guessing where the page ended up.
        if let target = AXScroll.target(for: window) {
            sideLog.notice("scroll path=ax-scrollbar")
            defer { AXScroll.finish(target) }
            return try await captureByScrollBar(window: window, screen: screen,
                                                target: target, progress: progress)
        }
        sideLog.notice("scroll path=wheel-events")
        return try await captureByWheelEvents(window: window, screen: screen, progress: progress)
    }

    // MARK: - Exact positioning via the AX scroll bar

    private func captureByScrollBar(window: SCWindow,
                                    screen: NSScreen,
                                    target: AXScroll.Target,
                                    progress: @escaping (Int) -> Void) async throws -> CGImage {
        let lo = AXScroll.minValue(of: target.bar)
        let hi = AXScroll.maxValue(of: target.bar)
        guard hi > lo else { throw ScrollCaptureError.noContent }

        AXScroll.setValue(lo, on: target.bar)
        try? await Task.sleep(nanoseconds: 140_000_000)
        guard let first = try await settledFrame(window: window, screen: screen) else {
            throw ScrollCaptureError.noContent
        }

        var stitcher = Stitcher(first: first)
        progress(stitcher.height)

        var previous = first
        var previousValue = AXScroll.value(of: target.bar) ?? lo
        var step = (hi - lo) * 0.1          // refined after the probe
        var contentPixels = 0.0

        // Probe a small step to learn how many pixels a unit of scroll bar travel is
        // worth, which gives the document height and therefore a sensible step size.
        let probe = (hi - lo) * 0.05
        if probe > 0, AXScroll.setValue(min(hi, lo + probe), on: target.bar) {
            try? await Task.sleep(nanoseconds: 140_000_000)
            if let frame = try await settledFrame(window: window, screen: screen) {
                let v = AXScroll.value(of: target.bar) ?? (lo + probe)
                let dv = max(1e-6, v - previousValue)
                if let moved = Self.matchOffset(previous: previous, next: frame, expected: nil), moved > 4 {
                    contentPixels = Double(moved) / dv
                    let viewport = Double(first.height)
                    let desired = 0.72 * viewport                 // advance per frame
                    step = min(hi - lo, max(probe, desired / max(viewport, contentPixels)))
                    stitcher.append(frame, advance: moved)
                    previous = frame
                    previousValue = v
                    progress(stitcher.height)
                }
            }
        }

        var guardCount = 0
        while guardCount < maxFrames {
            guardCount += 1
            let current = AXScroll.value(of: target.bar) ?? previousValue
            if current >= hi - 1e-9 { break }

            let next = min(hi, current + step)
            guard AXScroll.setValue(next, on: target.bar) else { break }
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let frame = try await settledFrame(window: window, screen: screen) else { break }

            let v = AXScroll.value(of: target.bar) ?? next
            let expected = contentPixels > 0 ? Int(((v - previousValue) * contentPixels).rounded()) : nil
            guard let moved = Self.matchOffset(previous: previous, next: frame,
                                               expected: expected), moved > 2 else { break }

            stitcher.append(frame, advance: moved)
            previous = frame
            previousValue = v
            progress(stitcher.height)
            if stitcher.height > maxHeight { throw ScrollCaptureError.tooTall(maxHeight) }
            if stitcher.height * stitcher.width > maxPixels {
                throw ScrollCaptureError.tooTall(maxHeight)
            }
        }

        guard let image = stitcher.finish() else { throw ScrollCaptureError.framesDidNotMatch }
        return image
    }

    // MARK: - Fallback: synthetic wheel events

    private func captureByWheelEvents(window: SCWindow,
                                      screen: NSScreen,
                                      progress: @escaping (Int) -> Void) async throws -> CGImage {
        // Park the pointer inside the window for the duration, then put it back.
        let savedCursor = CGEvent(source: nil)?.location ?? .zero
        warpCursor(to: CGPoint(x: window.frame.midX, y: window.frame.midY))
        defer { warpCursor(to: savedCursor) }
        try? await Task.sleep(nanoseconds: 80_000_000)

        // Always start from the top of the page, never from wherever the user left it.
        try await scrollToTop(window: window, screen: screen)

        guard let rawFirst = try await settledFrame(window: window, screen: screen) else {
            throw ScrollCaptureError.noContent
        }

        let requested = Int(CGFloat(rawFirst.height) * scrollFraction)

        // Probe one scroll. Two things come out of it: the real frame offset, and the
        // number of rows at the frame's bottom edge that are fixed window chrome
        // (rounded corner / shadow). Those rows never change when the page scrolls, and
        // stitching them is what left a dark band at every join.
        postScroll(direction: -1, pixels: requested, in: window)
        try? await Task.sleep(nanoseconds: 260_000_000)
        guard let rawSecond = try await settledFrame(window: window, screen: screen) else {
            // Page fits the window — one frame is the whole thing.
            guard let image = Stitcher(first: rawFirst).finish() else {
                throw ScrollCaptureError.framesDidNotMatch
            }
            return image
        }

        if Self.nearlyIdentical(rawFirst, rawSecond) {
            // Page fits the window: one frame is the whole thing.
            guard let image = Stitcher(first: rawFirst).finish() else {
                throw ScrollCaptureError.framesDidNotMatch
            }
            return image
        }

        let chrome = bottomChromeRows(rawFirst, rawSecond)
        let first = cropBottom(rawFirst, chrome)
        var previous = cropBottom(rawSecond, chrome)
        sideLog.notice("scroll chromeRows=\(chrome, privacy: .public)")

        var stitcher = Stitcher(first: first)
        progress(stitcher.height)

        guard let firstOffset = Self.matchOffset(previous: first, next: previous, expected: requested),
              firstOffset > 4 else {
            // Nothing moved: the page fits the window.
            guard let image = stitcher.finish() else { throw ScrollCaptureError.framesDidNotMatch }
            return image
        }
        stitcher.append(previous, advance: firstOffset)
        progress(stitcher.height)

        // At the bottom of a page the view rubber-bands, so frames keep differing by a
        // few pixels. Without this, the loop treats the bounce as fresh content and
        // keeps appending until it hits the size cap and fails.
        var weakSteps = 0

        for _ in 0..<maxFrames {
            postScroll(direction: -1, pixels: requested, in: window)
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard let raw = try await settledFrame(window: window, screen: screen) else { break }
            let after = cropBottom(raw, chrome)

            // Nothing changed on screen => we are at the end, whatever the matcher
            // claims. Checked before matching, because a self-similar page can produce
            // a confident false offset.
            if Self.nearlyIdentical(previous, after) { break }

            guard let offset = Self.matchOffset(previous: previous, next: after, expected: requested),
                  offset > 4, offset < previous.height - 4 else { break }

            if offset < requested / 3 {
                weakSteps += 1
                if weakSteps >= 2 { break }
            } else {
                weakSteps = 0
            }

            sideLog.notice("step req=\(requested, privacy: .public) got=\(offset, privacy: .public) h=\(stitcher.height, privacy: .public) weak=\(weakSteps, privacy: .public)")
            stitcher.append(after, advance: offset)
            previous = after
            progress(stitcher.height)
            if stitcher.height > maxHeight { throw ScrollCaptureError.tooTall(maxHeight) }
            if stitcher.height * stitcher.width > maxPixels {
                throw ScrollCaptureError.tooTall(maxHeight)
            }
        }

        guard let image = stitcher.finish() else { throw ScrollCaptureError.framesDidNotMatch }
        return image
    }

    // MARK: - Capture one frame

    private func captureFrame(window: SCWindow, screen: NSScreen) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let scale = screen.backingScaleFactor
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Rows at the bottom of the frame that did NOT change when the page scrolled —
    /// i.e. fixed window chrome (rounded corner, shadow, status bar), not content.
    /// Those rows get baked into every seam if they are stitched.
    private func bottomChromeRows(_ a: CGImage, _ b: CGImage, maxRows: Int = 48) -> Int {
        guard let ga = Self.grid(a), let gb = Self.grid(b), ga.w == gb.w, ga.h == gb.h else { return 0 }
        var rows = 0
        var y = ga.h - 1
        while y > ga.h - 1 - maxRows && y >= 0 {
            let base = y * ga.w * 3
            var total = 0
            var n = 0
            var x = 0
            while x < ga.w {
                let p = base + x * 3
                total += abs(Int(ga.data[p]) - Int(gb.data[p]))
                total += abs(Int(ga.data[p + 1]) - Int(gb.data[p + 1]))
                total += abs(Int(ga.data[p + 2]) - Int(gb.data[p + 2]))
                n += 3
                x += 2
            }
            let mean = n == 0 ? 999.0 : Double(total) / Double(n)
            if mean < 2.0 { rows += 1; y -= 1 } else { break }
        }
        return rows
    }

    /// True when two frames show the same thing. At the bottom of a page the view
    /// stops moving, and a matcher comparing the page with itself will happily lock
    /// onto a repeated section rhythm and invent a constant offset forever. That is
    /// what made long captures loop.
    private static func nearlyIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let ga = grid(a), let gb = grid(b), ga.w == gb.w, ga.h == gb.h else { return false }
        return mismatch(prev: ga, next: gb, offset: 0, skipTop: 0) < 1.0
    }

    private func cropBottom(_ image: CGImage, _ rows: Int) -> CGImage {
        guard rows > 0, rows < image.height - 8 else { return image }
        return image.cropping(to: CGRect(x: 0, y: 0,
                                         width: image.width,
                                         height: image.height - rows)) ?? image
    }

    /// Capture until two consecutive frames are identical. Stitching a frame caught
    /// mid-scroll is what produced blurred, misaligned seams.
    private func settledFrame(window: SCWindow, screen: NSScreen, tries: Int = 8) async throws -> CGImage? {
        var last: CGImage?
        var lastGrid: Grid?
        for _ in 0..<tries {
            guard let frame = try await captureFrame(window: window, screen: screen) else { return last }
            if let lg = lastGrid, let g = Self.grid(frame), g.w == lg.w, g.h == lg.h {
                var identical = true
                var i = 0
                while i < g.data.count {
                    if abs(Int(g.data[i]) - Int(lg.data[i])) > 1 { identical = false; break }
                    i += 3
                }
                if identical { return frame }
            }
            last = frame
            lastGrid = Self.grid(frame)
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        return last
    }

    /// Scroll the page to the very top before capturing, so a full-page shot always
    /// starts at the beginning rather than at the user's current scroll position.
    private func scrollToTop(window: SCWindow, screen: NSScreen) async throws {
        var lastGrid: Grid?
        for _ in 0..<30 {
            postScroll(direction: 1, pixels: Int(window.frame.height * 3), in: window)
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let frame = try await captureFrame(window: window, screen: screen),
                  let g = Self.grid(frame) else { return }
            if let lg = lastGrid, lg.w == g.w, lg.h == g.h {
                var moved = false
                var i = 0
                while i < g.data.count {
                    if abs(Int(g.data[i]) - Int(lg.data[i])) > 2 { moved = true; break }
                    i += 3
                }
                if !moved { return }
            }
            lastGrid = g
        }
    }

    // MARK: - Scrolling

    private func raise(window: SCWindow) {
        // Bring the owning app forward so it receives the synthetic scroll events.
        let pid = window.owningApplication?.processID
        guard let pid else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    /// macOS delivers scroll-wheel events to the window under the PHYSICAL cursor and
    /// ignores `CGEvent.location`. Unless the pointer is inside the target window, the
    /// page never moves and the capture silently returns a single viewport.
    private func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postScroll(direction: Int32, pixels: Int, in window: SCWindow) {
        let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 1,
                                  wheel1: direction * Int32(max(1, pixels)),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Frame matching

    /// Finds how far the content moved between two frames, by locating the previous
    /// frame's bottom rows inside the new frame's top rows. Returns the vertical offset
    /// in pixels, or nil when the frames share no matchable band.
    /// A downsampled luminance grid. Averaging each row to a single byte (the previous
    /// approach) throws away horizontal structure, so two different rows that happen to
    /// be equally bright looked identical and the seam landed a few pixels off. Sampling
    /// columns as well makes the match unambiguous.
    struct Grid {
        let w: Int
        let h: Int
        let data: [UInt8]
    }

    /// Colour samples, not luminance. Panels that differ only in hue have identical
    /// brightness, so a grey grid makes them interchangeable and the matcher locks onto
    /// a repeating section — the page then appears to scroll forever.
    static func grid(_ image: CGImage, columns: Int = 128) -> Grid? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let cw = min(columns, w)
        let step = max(1, w / cw)
        var out = [UInt8](repeating: 0, count: cw * h * 3)
        for y in 0..<h {
            let srcRow = y * w * 4
            let outRow = y * cw * 3
            for cx in 0..<cw {
                let sx = srcRow + min(w - 1, cx * step) * 4
                out[outRow + cx * 3] = pixels[sx]
                out[outRow + cx * 3 + 1] = pixels[sx + 1]
                out[outRow + cx * 3 + 2] = pixels[sx + 2]
            }
        }
        return Grid(w: cw, h: h, data: out)
    }

    /// Mean absolute difference between prev[offset...] and next[0...].
    /// `skipTop` ignores the first rows of `next`, which lets a sticky page header
    /// (present in every frame but not in the scrolled content) be discounted.
    static func mismatch(prev: Grid, next: Grid, offset: Int, skipTop: Int = 0) -> Double {
        let h = prev.h
        let count = h - offset
        guard count > skipTop + 8 else { return .greatestFiniteMagnitude }
        var total = 0
        var n = 0
        var i = skipTop
        while i < count {
            let pr = (offset + i) * prev.w * 3
            let nr = i * next.w * 3
            var x = 0
            while x < prev.w {
                let p = pr + x * 3
                let q = nr + x * 3
                total += abs(Int(prev.data[p]) - Int(next.data[q]))
                total += abs(Int(prev.data[p + 1]) - Int(next.data[q + 1]))
                total += abs(Int(prev.data[p + 2]) - Int(next.data[q + 2]))
                n += 3
                x += 2
            }
            i += 2
        }
        return n == 0 ? .greatestFiniteMagnitude : Double(total) / Double(n)
    }

    /// How far the content moved between two frames, in pixels.
    static func matchOffset(previous: CGImage, next: CGImage, expected: Int? = nil) -> Int? {
        guard let a = grid(previous), let b = grid(next), a.w == b.w, a.h == b.h else { return nil }

        let h = a.h
        let minOverlap = max(24, h / 12)
        let maxSearch = h - minOverlap
        guard maxSearch > minOverlap else { return nil }

        func search(_ lo: Int, _ hi: Int, step: Int) -> (offset: Int, score: Double)? {
            guard hi > lo else { return nil }
            var bestOffset = lo
            var bestScore = Double.greatestFiniteMagnitude
            func consider(_ offset: Int) {
                // Score normally, and again ignoring a possible sticky header.
                let s = min(mismatch(prev: a, next: b, offset: offset, skipTop: 0),
                            mismatch(prev: a, next: b, offset: offset, skipTop: 90))
                if s < bestScore { bestScore = s; bestOffset = offset }
            }
            var offset = lo
            while offset <= hi {
                consider(offset)
                offset += step
            }
            if step > 1 {
                let coarse = bestOffset
                for candidate in max(lo, coarse - step)..<(min(hi, coarse + step) + 1) {
                    consider(candidate)
                }
            }
            return (bestOffset, bestScore)
        }

        // Full range, then refine at 1px. Restricting the search to a window around the
        // requested scroll looked like an optimisation but was wrong: momentum makes a
        // page scroll FURTHER than the delta we posted, so the true offset fell outside
        // the window and the best in-window guess duplicated a band of the page.
        guard let coarse = search(minOverlap, maxSearch, step: 3) else { return nil }
        let refined = search(max(minOverlap, coarse.offset - 5),
                             min(maxSearch, coarse.offset + 5), step: 1)
        guard let best = refined, best.score < 4.0 else { return nil }

        // Periodic content (file lists, tables) can match near-perfectly at several
        // offsets. Among those, the one closest to how far we asked the page to move
        // is the real one.
        if let e = expected {
            var candidates: [(offset: Int, score: Double)] = []
            var o = minOverlap
            while o <= maxSearch {
                let s = min(mismatch(prev: a, next: b, offset: o, skipTop: 0),
                            mismatch(prev: a, next: b, offset: o, skipTop: 90))
                if s < max(2.0, best.score * 1.5) { candidates.append((o, s)) }
                o += 2
            }
            // Only break ties between effectively identical scores. Preferring the
            // requested offset over a clearly better match would duplicate a band
            // whenever momentum carried the page further than we asked.
            let tied = candidates.filter { $0.score <= best.score + 0.1 }
            if tied.count > 1,
               let closest = tied.min(by: { abs($0.offset - e) < abs($1.offset - e) }) {
                return closest.offset
            }
        }
        return best.offset
    }
}

// MARK: - Stitching

/// Accumulates frames into one tall image.
///
/// `advance` is how far the content moved between the previous frame and this one —
/// which is exactly the number of NEW rows this frame contributes. It is NOT the
/// overlap: the new rows are the BOTTOM `advance` rows, because the top ones repeat
/// what was already captured. Getting those two confused re-lays already-seen bands
/// and leaves a hard seam at every join.
struct Stitcher {
    private var frames: [(image: CGImage, advance: Int)] = []
    private(set) var width: Int
    private(set) var height: Int

    init(first: CGImage) {
        width = first.width
        height = first.height
        frames.append((first, first.height))
    }

    mutating func append(_ image: CGImage, advance: Int) {
        let a = max(1, min(advance, image.height))
        frames.append((image, a))
        height += a
    }

    func finish() -> CGImage? {
        guard height > 0, let ctx = CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        var placed = 0
        for (index, frame) in frames.enumerated() {
            let h = frame.image.height
            let advance = index == 0 ? h : frame.advance
            guard advance > 0 else { continue }
            // Keep the bottom `advance` rows (top-left origin for cropping).
            let src = CGRect(x: 0, y: CGFloat(h - advance),
                             width: CGFloat(frame.image.width), height: CGFloat(advance))
            guard let cropped = frame.image.cropping(to: src) else { continue }
            // Bottom-origin placement: first frame at the top of the canvas.
            let dst = CGRect(x: 0, y: CGFloat(height - placed - advance),
                             width: CGFloat(width), height: CGFloat(advance))
            ctx.draw(cropped, in: dst)
            placed += advance
        }
        return ctx.makeImage()
    }
}

// MARK: - Progress HUD

/// A non-activating pill that reports progress while the page is being captured.
/// It must never become key — taking focus would steal the scroll target away.
final class ScrollHUD: NSPanel {
    private let label = NSTextField(labelWithString: "Capturing page…")
    private let spinner = NSProgressIndicator()

    init() {
        let size = NSSize(width: 320, height: 64)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true

        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.96).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.frame = NSRect(x: 20, y: 22, width: 18, height: 18)

        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.frame = NSRect(x: 52, y: 21, width: 250, height: 20)

        box.addSubview(spinner)
        box.addSubview(label)
        contentView = box
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 60))
        }
        orderFrontRegardless()
        spinner.startAnimation(nil)
    }

    func update(pixels: Int) {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let n = f.string(from: NSNumber(value: pixels)) ?? "\(pixels)"
        label.stringValue = "Capturing page · \(n) px"
    }
}

#if DEBUG
// MARK: - Self test

extension ScrollCapture {
    /// Builds a synthetic "long page", slices it into overlapping frames the way the
    /// scroll loop would, then checks that the matcher recovers the right offset and
    /// that stitching reconstructs the original. Prints a report to stderr.
    static func debugSelfTest() -> String {
        let width = 420, pageHeight = 3600, frameHeight = 420, step = 330
        var out: [String] = []

        // A page with strong per-row structure so the matcher has something to lock onto.
        guard let ctx = CGContext(data: nil, width: width, height: pageHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "scrolltest: could not create context"
        }
        // Pseudo-random stripes. A repeating pattern makes many offsets score equally
        // well, which is a property of the fixture, not of real pages.
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in stride(from: 0, to: pageHeight, by: 10) {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let r = CGFloat((rng >> 33) % 256) / 255.0
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let g = CGFloat((rng >> 33) % 256) / 255.0
            ctx.setFillColor(red: r, green: g, blue: 1 - r, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 8))
        }
        guard let page = ctx.makeImage() else { return "scrolltest: no page image" }

        // Slice into frames, top to bottom.
        var frames: [CGImage] = []
        var top = 0
        while top + frameHeight <= pageHeight {
            if let f = page.cropping(to: CGRect(x: 0, y: top, width: width, height: frameHeight)) {
                frames.append(f)
            }
            top += step
        }
        out.append("frames=\(frames.count) expectedStep=\(step)")

        // Every consecutive pair should report exactly `step`.
        var bad = 0
        for i in 1..<frames.count {
            let got = matchOffset(previous: frames[i - 1], next: frames[i], expected: step)
            if got != step {
                bad += 1
                out.append("  pair \(i): got \(got.map(String.init) ?? "nil") expected \(step)")
            }
        }
        out.append("offsetMatches=\(frames.count - 1 - bad)/\(frames.count - 1)")



        // Stitch and compare height + a few sampled rows against the original.
        var stitcher = Stitcher(first: frames[0])
        for i in 1..<frames.count {
            stitcher.append(frames[i], advance: step)
        }
        let stitched = stitcher.finish()
        out.append("stitchedHeight=\(stitched?.height ?? -1) expectedApprox=\(frameHeight + step * (frames.count - 1))")

        // The real test: the stitched image must match the source page pixel for pixel.
        // Any seam shows up here as a non-zero score.
        if let stitched,
           let reference = page.cropping(to: CGRect(x: 0, y: 0, width: width, height: stitched.height)),
           let rg = grid(reference), let sg = grid(stitched) {
            let diff = mismatch(prev: rg, next: sg, offset: 0)
            out.append(String(format: "pixelDiff=%.3f %@", diff,
                              diff < 0.5 ? "SEAMLESS" : "SEAMS PRESENT"))
        }

        let report = out.joined(separator: "\n")
        NSLog("SIDESHOT_SCROLLTEST\n%@", report)
        return report
    }
}
#endif
