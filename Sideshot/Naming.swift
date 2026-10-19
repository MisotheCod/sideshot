import Foundation

/// Cam's capture naming convention:
///   [TYPE]_[MMMddyy]_[HH.mm].[ext]
///   TYPE: SS = screenshot, SR = screen recording
///   Collisions get "_2", "_3", … appended before the extension.
enum CaptureNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "MMMddyy'_'HH'.'mm"   // "Oct1826_13.05"
        return f
    }()

    static func timestamp() -> String { formatter.string(from: Date()) }
    static func screenshotName() -> String { "SS_\(timestamp()).png" }
    static func recordingName() -> String { "SR_\(timestamp()).mov" }
    static func clipName() -> String { "SR_\(timestamp())_clip.mov" }

    /// Append _2, _3, … before the extension if the file already exists.
    static func uniqueURL(for base: URL) -> URL {
        var candidate = base
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = base.deletingPathExtension().lastPathComponent
            let ext = base.pathExtension
            candidate = base.deletingLastPathComponent().appendingPathComponent("\(stem)_\(i).\(ext)")
            i += 1
        }
        return candidate
    }
}