import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Deterministic scrolling through the Accessibility API.
///
/// Posting wheel events (what we did before) is a guess: the page may smooth-scroll,
/// rubber-band, ignore the event, or route it to a nested scroll container — which is
/// why short pages silently captured only the first screen. A standard `AXScrollArea`
/// exposes a writable vertical scroll bar whose value runs 0…1, so we can jump to an
/// exact position and read it back, the way GoFullPage does with `window.scrollTo`.
enum AXScroll {

    struct Target {
        let bar: AXUIElement
        let area: AXUIElement
        let app: AXUIElement
    }

    /// Chromium (Arc, Chrome, Electron) and WebKit build their accessibility tree
    /// lazily. Until a client asks, a browser window has no AXScrollArea at all, so
    /// full-page capture silently falls back to wheel events. These two switches are
    /// what VoiceOver sets to force the tree to materialise.
    private static func enableAccessibilityTree(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Turn the forced tree back off so we don't leave the app in an expensive mode.
    static func finish(_ target: Target) {
        AXUIElementSetAttributeValue(target.app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }

    // MARK: - Attribute helpers

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func value(of bar: AXUIElement) -> Double? {
        (copy(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    static func minValue(of bar: AXUIElement) -> Double {
        (copy(bar, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
    }

    static func maxValue(of bar: AXUIElement) -> Double {
        (copy(bar, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 1
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    @discardableResult
    static func setValue(_ v: Double, on bar: AXUIElement) -> Bool {
        let lo = minValue(of: bar), hi = maxValue(of: bar)
        let clamped = min(hi, max(lo, v))
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                            NSNumber(value: clamped)) == .success
    }

    // MARK: - Finding the scroller

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let pRef = copy(element, kAXPositionAttribute),
              let sRef = copy(element, kAXSizeAttribute) else { return nil }
        // CoreFoundation types can't be conditionally downcast in Swift 6.
        let p = pRef as! AXValue
        let s = sRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &point)
        AXValueGetValue(s, .cgSize, &size)
        guard size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Depth-first search for the largest scroll area — the main document, not a sidebar.
    private static func largestScrollArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 24 else { return nil }
        var best: AXUIElement?
        var bestArea: CGFloat = 0

        if let role = copy(element, kAXRoleAttribute) as? String, role == "AXScrollArea",
           let f = frame(of: element) {
            best = element
            bestArea = f.width * f.height
        }

        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return best }
        for child in children {
            if let candidate = largestScrollArea(in: child, depth: depth + 1),
               let f = frame(of: candidate) {
                let area = f.width * f.height
                if area > bestArea { best = candidate; bestArea = area }
            }
        }
        return best
    }

    /// The vertical scroll bar of the window's main scroll area, if it has a writable one.
    static func target(for window: SCWindow) -> Target? {
        guard AXIsProcessTrusted(), let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        enableAccessibilityTree(app)
        // The tree is built asynchronously after the switch flips.
        usleep(180_000)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            return nil
        }

        // Match the SCWindow by title first, then fall back to the largest window.
        let wanted = window.title ?? ""
        var chosen: AXUIElement?
        for w in windows {
            if let t = copy(w, kAXTitleAttribute) as? String, !wanted.isEmpty, t == wanted {
                chosen = w
                break
            }
        }
        if chosen == nil {
            chosen = windows.max { a, b in
                let fa = frame(of: a) ?? .zero, fb = frame(of: b) ?? .zero
                return fa.width * fa.height < fb.width * fb.height
            }
        }
        guard let axWindow = chosen, let area = largestScrollArea(in: axWindow) else { return nil }
        guard let barRef = copy(area, kAXVerticalScrollBarAttribute) else { return nil }
        let bar = barRef as! AXUIElement
        guard isSettable(bar, kAXValueAttribute), value(of: bar) != nil else { return nil }
        return Target(bar: bar, area: area, app: app)
    }
}
