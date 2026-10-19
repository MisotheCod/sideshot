import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Screen recording via SCStream → AVAssetWriter (H.264 MP4) — the same stack
/// CleanShot X's binary reveals (SCStream + AVAssetWriter, H.264).
final class Recorder: NSObject {
    static let shared = Recorder()

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var firstPTS: CMTime = .invalid
    private(set) var isRecording = false

    var onFinished: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    /// Fullscreen or region recording. Pass `region` nil for the whole display.
    func start(region: CGRect?, screen: NSScreen) async throws {
        guard !isRecording else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let display = matchDisplay(screen, in: content.displays)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = screen.backingScaleFactor

        let width: Int
        let height: Int
        let sourceRect: CGRect?
        if let region {
            width = max(2, Int(region.width * scale))
            height = max(2, Int(region.height * scale))
            sourceRect = CGRect(x: region.origin.x * scale,
                                y: region.origin.y * scale,
                                width: CGFloat(width),
                                height: CGFloat(height))
        } else {
            width = max(2, Int(display.width) * max(1, Int(scale)))
            height = max(2, Int(display.height) * max(1, Int(scale)))
            sourceRect = nil
        }
        try await begin(filter: filter, width: width, height: height, sourceRect: sourceRect)
    }

    /// Record a specific window (⌘⇧5 → Window).
    func start(window: SCWindow, screen: NSScreen) async throws {
        guard !isRecording else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = screen.backingScaleFactor
        let width = max(2, Int(window.frame.width * scale))
        let height = max(2, Int(window.frame.height * scale))
        try await begin(filter: filter, width: width, height: height, sourceRect: nil)
    }

    private func begin(filter: SCContentFilter, width: Int, height: Int, sourceRect: CGRect?) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sideshot-rec-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        // nil source attributes: accept whatever pixel format ScreenCaptureKit delivers.
        // (Pinning a format/width/height here silently drops frames → empty MP4 that won't play.)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sideshot.recorder"))

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "SideshotRecorder", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start"])
        }
        writer.startSession(atSourceTime: .zero)
        try await stream.startCapture()

        self.stream = stream
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.outputURL = url
        self.isRecording = true
        self.firstPTS = .invalid
    }

    func stop() async -> URL? {
        guard isRecording, let writer, let url = outputURL else { return nil }
        isRecording = false
        try? await stream?.stopCapture()
        input?.markAsFinished()
        await writer.finishWriting()
        let status = writer.status
        stream = nil; self.writer = nil; input = nil; adaptor = nil; outputURL = nil
        if status == .completed {
            return url
        } else {
            onError?(writer.error ?? NSError(domain: "SideshotRecorder", code: 2,
                                             userInfo: [NSLocalizedDescriptionKey: "recording finished with status \(status.rawValue)"]))
            return nil
        }
    }

    private func matchDisplay(_ screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let id = CGDirectDisplayID(n.uint32Value)
            if let match = displays.first(where: { $0.displayID == id }) { return match }
        }
        return displays[0]
    }

    static func thumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 360)
        if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return nil
    }
}

extension Recorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, isRecording, let input, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == .invalid { firstPTS = pts }
        let time = CMTimeSubtract(pts, firstPTS)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        adaptor?.append(pixelBuffer, withPresentationTime: time)
    }
}

extension Recorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
        onError?(error)
    }
}