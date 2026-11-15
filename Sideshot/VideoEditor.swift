import AppKit
import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - Window

final class VideoEditorWindow: NSWindow {
    init(assetURL: URL, saveDirectory: URL) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        center()
        title = (assetURL.lastPathComponent as NSString).deletingPathExtension
        minSize = NSSize(width: 680, height: 580)

        let view = VideoEditorView(assetURL: assetURL, saveDirectory: saveDirectory) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        contentView = hosting
        setContentSize(NSSize(width: 820, height: 640))
    }
}

// MARK: - Player controller (playback time for the scrubber)

final class PlayerController: ObservableObject {
    let player: AVPlayer
    @Published var currentTime: Double = 0
    @Published var isPlaying: Bool = false

    /// When set, playback is confined to this span and loops inside it, so Play
    /// previews exactly the trimmed clip rather than the whole recording.
    var playRange: ClosedRange<Double>? {
        didSet { applyEndTime() }
    }

    private var looping = false
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let seconds = t.seconds
            self.currentTime = seconds
            let playing = self.player.timeControlStatus == .playing
            // Treat the loop seam as still-playing, otherwise the big play glyph
            // flashes for one frame every time the selection restarts.
            self.isPlaying = playing || self.looping

            // Loop the selection. forwardPlaybackEndTime halts exactly at the out
            // point, so also catch the stopped-at-the-end case.
            guard let r = self.playRange, self.looping, seconds.isFinite else { return }
            if seconds >= r.upperBound - 0.02 || (!playing && seconds >= r.upperBound - 0.2) {
                self.player.seek(to: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.play()
            }
        }
    }

    /// Stop the item exactly at the out point rather than overshooting it.
    private func applyEndTime() {
        if let r = playRange {
            player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: r.upperBound,
                                                               preferredTimescale: 600)
        } else {
            player.currentItem?.forwardPlaybackEndTime = .invalid
        }
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func togglePlay() {
        if player.rate > 0 {
            pause()
            return
        }
        if let r = playRange {
            // Pressing Play outside the selection should jump to its start, not play
            // footage the user has already trimmed away.
            if currentTime < r.lowerBound + 0.02 || currentTime >= r.upperBound - 0.05 {
                seek(to: r.lowerBound)
            }
            looping = true
        }
        player.play()
    }

    func pause() {
        player.pause()
        looping = false
        isPlaying = false
    }

    func resume() {
        looping = playRange != nil
        player.play()
    }

    deinit {
        if let o = observer { player.removeTimeObserver(o) }
    }
}

// MARK: - Editor view

struct VideoEditorView: View {
    let assetURL: URL
    let saveDirectory: URL
    let onClose: () -> Void

    @StateObject private var controller: PlayerController
    private let asset: AVURLAsset
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var stripImage: NSImage?
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var wasPlaying = false

    init(assetURL: URL, saveDirectory: URL, onClose: @escaping () -> Void) {
        self.assetURL = assetURL
        self.saveDirectory = saveDirectory
        self.onClose = onClose
        self.asset = AVURLAsset(url: assetURL)
        _controller = StateObject(wrappedValue: PlayerController(url: assetURL))
    }

    var body: some View {
        VStack(spacing: 14) {
            PlayerContainer(player: controller.player)
                .frame(height: 310)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    // transparent tap catcher above the player
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.togglePlay() }
                }
                .overlay {
                    if !controller.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(radius: 8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: controller.isPlaying)

            ScrubTrimBar(duration: duration,
                         stripImage: stripImage,
                         start: $trimStart,
                         end: $trimEnd,
                         playhead: controller.currentTime,
                         onScrubBegan: scrubBegan,
                         onScrub: scrub,
                         onScrubEnded: scrubEnded)
                .frame(height: 74)
                .padding(.horizontal, 24)

            HStack {
                Text(timeString(trimStart))
                Spacer()
                Text(timeString(controller.currentTime))
                    .monospacedDigit()
                Spacer()
                Text(timeString(trimEnd))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 28)

            HStack(spacing: 12) {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: { controller.togglePlay() }) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                Spacer()
                if isExporting {
                    ProgressView().controlSize(.small)
                } else if let msg = exportMessage {
                    Text(msg).font(.callout).foregroundColor(.secondary)
                }
                Button("Save As…") { Task { await exportSelection() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || duration <= 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: trimStart) { _, _ in syncPlayRange() }
        .onChange(of: trimEnd) { _, _ in syncPlayRange() }
    }

    // MARK: - Loading

    private func load() {
        Task {
            do {
                let d = try await asset.load(.duration)
                let secs = d.seconds
                let dur = secs.isFinite && secs > 0 ? secs : 0
                let frames = await generateFrames(duration: dur)
                await MainActor.run {
                    duration = dur
                    trimStart = 0
                    trimEnd = dur
                    stripImage = Self.compositeStrip(frames: frames)
                    syncPlayRange()
                }
            } catch {
                await MainActor.run { duration = 0 }
            }
        }
    }

    private func generateFrames(duration: Double) async -> [NSImage] {
        let count = 18
        guard duration > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 90)
        var imgs: [NSImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * Double(i) / Double(count - 1), preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                imgs.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        return imgs
    }

    /// Bake the frame strip into ONE image so the scrubber redraws cheap (buttery playhead).
    static func compositeStrip(frames: [NSImage]) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        let w: CGFloat = 1200, h: CGFloat = 74
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let fw = w / CGFloat(frames.count)
        for (i, fr) in frames.enumerated() {
            let dst = NSRect(x: CGFloat(i) * fw, y: 0, width: fw, height: h)
            let frSize = fr.size
            guard frSize.width > 0, frSize.height > 0 else { continue }
            let dstAspect = fw / h
            let srcAspect = frSize.width / frSize.height
            var src = NSRect(origin: .zero, size: frSize)
            if srcAspect > dstAspect {
                let nw = frSize.height * dstAspect
                src = NSRect(x: (frSize.width - nw) / 2, y: 0, width: nw, height: frSize.height)
            } else {
                let nh = frSize.width / dstAspect
                src = NSRect(x: 0, y: (frSize.height - nh) / 2, width: frSize.width, height: nh)
            }
            fr.draw(in: dst, from: src, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: nil)
        }
        img.unlockFocus()
        return img
    }

    // MARK: - Scrubbing (pause while scrubbing, resume after — the Apple-quality detail)

    private func scrubBegan() {
        wasPlaying = controller.isPlaying
        controller.pause()
    }

    private func scrub(to t: Double) {
        controller.seek(to: t)
    }

    private func scrubEnded() {
        if wasPlaying { controller.resume() }
    }

    /// Keep the player's confinement in sync with the handles as they move.
    private func syncPlayRange() {
        guard duration > 0 else { controller.playRange = nil; return }
        let s = max(0, min(trimStart, trimEnd - 0.1))
        let e = min(duration, max(trimEnd, s + 0.1))
        // Only confine playback once the user has actually trimmed something;
        // an untouched clip should still play straight through once.
        let trimmed = s > 0.05 || e < duration - 0.05
        controller.playRange = trimmed ? (s...e) : nil
    }

    // MARK: - Export

    private func exportSelection() async {
        guard duration > 0, !isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CaptureNaming.clipName()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = saveDirectory
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        isExporting = true
        exportMessage = nil
        defer { isExporting = false }

        let s = max(0, min(trimStart, duration - 0.2))
        let e = min(duration, max(trimEnd, s + 0.2))
        let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                end: CMTime(seconds: e, preferredTimescale: 600))

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            exportMessage = "Export failed"
            return
        }
        exporter.outputURL = dest
        exporter.outputFileType = .mov
        exporter.timeRange = range

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }
        exportMessage = exporter.status == .completed ? "Saved" : "Export failed"
    }

    private func timeString(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Native player view (no inline controls — the strip below IS the scrubber)

struct PlayerContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Unified scrub + trim bar (QuickTime-style)

struct ScrubTrimBar: View {
    let duration: Double
    let stripImage: NSImage?
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    let onScrubBegan: () -> Void
    let onScrub: (Double) -> Void
    let onScrubEnded: () -> Void

    private let minSpan = 0.4
    @State private var scrubbing = false
    @State private var hoverStart = false
    @State private var hoverEnd = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let ratio = duration > 0 ? Double(w) / duration : 0
            let sx = CGFloat(start) * CGFloat(ratio)
            let ex = CGFloat(end) * CGFloat(ratio)
            let px = CGFloat(max(0, min(playhead, duration))) * CGFloat(ratio)

            ZStack(alignment: .leading) {
                if let strip = stripImage {
                    Image(nsImage: strip)
                        .resizable()
                        .frame(width: w, height: h)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                }

                // dim outside the selected range
                Color.black.opacity(0.55).frame(width: max(0, sx), height: h)
                Color.black.opacity(0.55).frame(width: max(0, w - ex), height: h).offset(x: ex)

                // selection outline
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: max(2, ex - sx), height: h)
                    .offset(x: sx)

                // playhead
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: h)
                    .offset(x: max(0, px) - 1)
                    .shadow(color: .black.opacity(0.5), radius: 1)

                handleGuide(x: sx, width: w, time: $start, hover: $hoverStart, isStart: true)
                handleGuide(x: ex, width: w, time: $end, hover: $hoverEnd, isStart: false)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .coordinateSpace(name: "scrub")
            .gesture(scrubGesture(width: w))
        }
        .frame(height: 74)
    }

    private func handleGuide(x: CGFloat, width w: CGFloat, time: Binding<Double>, hover: Binding<Bool>, isStart: Bool) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .scaleEffect(hover.wrappedValue ? 1.18 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hover.wrappedValue)
            .offset(x: x - 10)
            .onHover { hover.wrappedValue = $0 }
            .gesture(
                DragGesture(coordinateSpace: .named("scrub"))
                    .onChanged { v in
                        guard duration > 0 else { return }
                        let t = max(0, min(duration, Double(v.location.x / max(1, w)) * duration))
                        if isStart { time.wrappedValue = min(t, end - minSpan) }
                        else { time.wrappedValue = max(t, start + minSpan) }
                    }
            )
    }

    private func scrubGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("scrub"))
            .onChanged { v in
                guard duration > 0 else { return }
                let t = max(0, min(duration, Double(v.location.x / max(1, w)) * duration))
                if !scrubbing {
                    scrubbing = true
                    onScrubBegan()
                }
                onScrub(t)
            }
            .onEnded { _ in
                if scrubbing {
                    scrubbing = false
                    onScrubEnded()
                }
            }
    }
}