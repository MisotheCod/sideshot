import AppKit
import ScreenCaptureKit

struct Capture {
    let image: CGImage
    let pointSize: CGSize
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case cropFailed
    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Could not match the target display."
        case .cropFailed: return "Failed to crop the captured image."
        }
    }
}

/// ScreenCaptureKit-backed captures — the same framework CleanShot X (and Apple's own
/// screenshot tool) builds on. Stills go through SCScreenshotManager; recording will
/// use SCStream + AVAssetWriter when we add video.
final class CaptureEngine {
    static let shared = CaptureEngine()
    private init() {}

    func captureMainDisplay() async throws -> Capture {
        try await capture(rect: nil, screen: NSScreen.main ?? NSScreen.screens.first)
    }

    func captureRegion(rect: CGRect, on screen: NSScreen? = nil) async throws -> Capture {
        try await capture(rect: rect, screen: screen ?? NSScreen.main ?? NSScreen.screens.first)
    }

    func captureWindow(_ window: SCWindow, screen: NSScreen) async throws -> Capture {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, screen.backingScaleFactor)
        var config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return Capture(image: image, pointSize: pointSize)
    }

    private func capture(rect: CGRect?, screen: NSScreen?) async throws -> Capture {
        guard let screen else { throw CaptureError.displayNotFound }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = matchDisplay(screen, in: content.displays) else { throw CaptureError.displayNotFound }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor
        var config = SCStreamConfiguration()
        config.width = Int(display.width) * Int(scale)
        config.height = Int(display.height) * Int(scale)
        config.showsCursor = false
        config.capturesAudio = false

        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let result: CGImage
        let pointSize: CGSize
        if let rect {
            // rect is in top-left-origin points within the target screen (matches SCK's
            // top-left pixel origin), so crop = rect * backingScaleFactor.
            let fullRect = CGRect(x: 0, y: 0, width: CGFloat(full.width), height: CGFloat(full.height))
            let pixelRect = CGRect(x: rect.origin.x * scale,
                                   y: rect.origin.y * scale,
                                   width: rect.width * scale,
                                   height: rect.height * scale)
                .integral.intersection(fullRect)
            guard pixelRect.width > 0, pixelRect.height > 0, let cropped = full.cropping(to: pixelRect) else {
                throw CaptureError.cropFailed
            }
            result = cropped
            pointSize = CGSize(width: pixelRect.width / scale, height: pixelRect.height / scale)
        } else {
            result = full
            pointSize = CGSize(width: CGFloat(full.width) / scale, height: CGFloat(full.height) / scale)
        }
        return Capture(image: result, pointSize: pointSize)
    }

    private func matchDisplay(_ screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let id = CGDirectDisplayID(n.uint32Value)
            if let match = displays.first(where: { $0.displayID == id }) { return match }
        }
        return displays.first
    }
}