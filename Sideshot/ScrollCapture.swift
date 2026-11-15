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

    /// How much of the window we scroll past each step. Leaving overlap is what lets the
    /// matcher find the seam; 0.78 is a compromise between speed and reliability.
    private let scrollFraction: CGFloat = 0.78
    private let maxFrames = 80
    private let maxHeight = 30_000

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

        // The window must be the frontmost thing receiving scroll events; otherwise the
        // events land wherever the cursor is. Raise it first.
        raise(window: window)
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Always start from the top of the page, never from wherever the user left it.
        try await scrollToTop(window: window, screen: screen)

        guard let first = try await settledFrame(window: window, screen: screen) else {
            throw ScrollCaptureError.noContent
        }

        var stitcher = Stitcher(first: first)
        progress(stitcher.height)

        var direction: Int32 = -1   // try scrolling "down" first; flipped below if wrong
        var directionLocked = false
        var lastOffset: Int = 0

        for _ in 0..<maxFrames {
            guard let before = try await settledFrame(window: window, screen: screen) else { break }

            postScroll(direction: direction, pixels: Int(CGFloat(before.height) * scrollFraction), in: window)
            try? await Task.sleep(nanoseconds: 260_000_000)

            // Wait for the scroll animation to stop: capturing mid-scroll is what
            // produced the visible seams (a frame caught between two positions).
            guard let after = try await settledFrame(window: window, screen: screen) else { break }

            // If nothing moved, we're either at the end of the page or scrolling the
            // wrong way. Flip once; if it still doesn't move, we're done.
            let requested = Int(CGFloat(before.height) * scrollFraction)
            guard let offset = Self.matchOffset(previous: before, next: after, expected: requested),
                  offset > 4 else {
                if !directionLocked {
                    direction = -direction
                    directionLocked = true
                    continue
                }
                break
            }
            directionLocked = true

            // A full-height match means the frame is identical: we've hit the bottom.
            if offset >= before.height - 4 { break }

            stitcher.append(after, advance: offset)
            lastOffset = offset
            progress(stitcher.height)

            if stitcher.height > maxHeight {
                throw ScrollCaptureError.tooTall(maxHeight)
            }
            if lastOffset == 0 { break }
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

    static func grid(_ image: CGImage, columns: Int = 128) -> Grid? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let cw = min(columns, w)
        let step = max(1, w / cw)
        var out = [UInt8](repeating: 0, count: cw * h)
        for y in 0..<h {
            let row = y * w
            let outRow = y * cw
            for cx in 0..<cw {
                out[outRow + cx] = pixels[row + min(w - 1, cx * step)]
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
            let pr = (offset + i) * prev.w
            let nr = i * next.w
            var x = 0
            while x < prev.w {
                total += abs(Int(prev.data[pr + x]) - Int(next.data[nr + x]))
                n += 1
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

        // We posted a known number of pixels, and browsers honour it closely. Searching
        // near that first avoids latching onto the wrong repeat of periodic content
        // (table rows, lists) — which is what shifts a seam by a whole row.
        if let e = expected, e > minOverlap {
            let pad = max(24, e / 6)
            let lo = max(minOverlap, e - pad)
            let hi = min(maxSearch, e + pad)
            // Fine 1px sweep: a coarse step can skip the exact offset on content where
            // every misalignment scores similarly, and one row off is a visible seam.
            if let best = search(lo, hi, step: 1), best.score < 4.0 { return best.offset }
        }

        // Tight threshold: a fuzzy match is what leaves a visible line at the seam.
        if let best = search(minOverlap, maxSearch, step: 3), best.score < 4.0 { return best.offset }
        return nil
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
    private let width: Int
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
