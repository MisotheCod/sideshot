import AppKit
import Carbon
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let thumbnails = ThumbnailManager()
    private var selectionWindow: SelectionOverlayWindow?
    private var recordingSelection = false
    private var recordIndicator: RecordIndicator?
    private var onboardingWindow: OnboardingWindow?
    private var annotateWindow: AnnotateWindow?
    private var videoEditorWindows: [VideoEditorWindow] = []
    private var recordModePanel: RecordModePanel?
    private var windowSelectionWindow: NSWindow?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: a menu-bar hotkey app must never run twice.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cam.sideshot")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }

        NSApp.setActivationPolicy(.accessory)
        Recorder.shared.onFinished = { [weak self] url in
            Task { @MainActor in self?.handleFinishedRecording(url) }
        }
        Recorder.shared.onError = { [weak self] error in
            Task { @MainActor in self?.notifyError(error) }
        }
        setupStatusItem()
        registerHotkeys()
        if !UserDefaults.standard.bool(forKey: "DidShowOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showOnboarding() }
        }
        #if DEBUG
        runSelfTestIfRequested()
        #endif
    }

    // MARK: - Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Sideshot")
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            return it
        }

        menu.addItem(item("Capture Area", #selector(captureArea), key: "4", mods: [.command, .shift]))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), key: "3", mods: [.command, .shift]))
        menu.addItem(item("Capture Window", #selector(captureWindow)))
        menu.addItem(.separator())
        menu.addItem(item("Record…", #selector(recordToggle), key: "5", mods: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Copy Last Capture", #selector(copyLast)))
        menu.addItem(item("Save Last Capture", #selector(saveLast)))
        menu.addItem(.separator())

        let locItem = NSMenuItem(title: "Save Location: \(saveDirectoryLeafName())", action: nil, keyEquivalent: "")
        locItem.isEnabled = false
        menu.addItem(locItem)
        menu.addItem(item("Choose Save Location…", #selector(chooseSaveLocation)))
        menu.addItem(.separator())
        menu.addItem(item("Welcome…", #selector(showOnboardingAction)))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Sideshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Save location

    private var saveDirectory: URL {
        if let p = UserDefaults.standard.string(forKey: "SaveDirectoryPath") {
            let u = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func saveDirectoryLeafName() -> String {
        let name = saveDirectory.lastPathComponent
        return name.isEmpty ? "Desktop" : name
    }

    @objc private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Screenshots and recordings will be saved here."
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "SaveDirectoryPath")
            statusItem.menu = buildMenu()
        }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        hotkeyManager.register(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), id: 1) { [weak self] in
            self?.captureArea()
        }
        hotkeyManager.register(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), id: 2) { [weak self] in
            self?.captureFullscreen()
        }
        hotkeyManager.register(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey), id: 3) { [weak self] in
            self?.recordToggle()
        }
        hotkeyManager.install()
    }

    // MARK: - Screenshot capture

    @objc func captureArea() { presentSelection(recording: false) }

    @objc func captureFullscreen() {
        Task {
            do {
                let capture = try await CaptureEngine.shared.captureMainDisplay()
                await MainActor.run { self.handleImageCapture(capture) }
            } catch { self.notifyError(error) }
        }
    }

    private func presentSelection(recording: Bool) {
        guard selectionWindow == nil else { return }
        recordingSelection = recording
        let win = SelectionOverlayWindow { [weak self] rect, screen in
            guard let self else { return }
            self.selectionWindow = nil
            self.updateEscState()
            if self.recordingSelection {
                self.startRecording(region: rect, screen: screen)
            } else {
                Task {
                    do {
                        let capture = try await CaptureEngine.shared.captureRegion(rect: rect, on: screen)
                        await MainActor.run { self.handleImageCapture(capture) }
                    } catch { self.notifyError(error) }
                }
            }
        }
        selectionWindow = win
        win.show()
        updateEscState()
    }

    private func handleImageCapture(_ capture: Capture) {
        copyImageToClipboard(capture)
        let item = CaptureItem(image: NSImage(cgImage: capture.image, size: capture.pointSize))
        thumbnails.add(item, actions: cardActions())
    }

    // MARK: - Thumbnail actions

    private func cardActions() -> CardActions {
        CardActions(
            onCopy: { [weak self] item in self?.copyItem(item) },
            onSave: { [weak self] item in self?.saveItem(item) },
            onEdit: { [weak self] item in self?.editItem(item) },
            onRemove: { [weak self] item in self?.removeItem(item) },
            onDragOut: { [weak self] item in self?.dragOutItem(item) },
            onPreview: { [weak self] item in self?.previewItem(item) }
        )
    }

    private func copyImageToClipboard(_ capture: Capture) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: capture.image, size: capture.pointSize)])
    }

    private func copyItem(_ item: CaptureItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let url = item.videoURL {
            pb.writeObjects([url as NSURL])
        } else {
            pb.writeObjects([item.image])
        }
        flashAndRemove(item, label: "Copied")
    }

    private func saveItem(_ item: CaptureItem) {
        if item.isVideo {
            guard let src = item.videoURL else { return }
            let dest = CaptureNaming.uniqueURL(for: nextRecordingURL())
            do {
                try FileManager.default.copyItem(at: src, to: dest)
            } catch {
                notifyError(error)
                return
            }
            flashAndRemove(item, label: "Saved")
        } else {
            guard let png = pngData(for: item.image) else { return }
            do {
                try png.write(to: CaptureNaming.uniqueURL(for: nextScreenshotURL()))
            } catch {
                notifyError(error)
                return
            }
            flashAndRemove(item, label: "Saved")
        }
    }

    private func editItem(_ item: CaptureItem) {
        guard let url = item.videoURL else { return }
        openVideoEditor(for: url)
    }

    /// Double-click a card: recordings open the trim editor, screenshots open the annotator.
    private func previewItem(_ item: CaptureItem) {
        if item.isVideo, let url = item.videoURL {
            openVideoEditor(for: url)
            return
        }
        openAnnotator(for: item.image)
    }

    private func openAnnotator(for image: NSImage) {
        annotateWindow?.close()
        let w = AnnotateWindow(image: image, saveDirectory: saveDirectory)
        annotateWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Remove a card: discard any unsaved recording. (Drag temp files are left in place
/// so an in-flight drag can still complete its drop.)
    private func removeItem(_ item: CaptureItem) {
        if let v = item.videoURL { try? FileManager.default.removeItem(at: v) }
        thumbnails.remove(item)
    }

    /// Fired when the user starts dragging a card out — dismiss it once the drop finishes.
    private func dragOutItem(_ item: CaptureItem) {
        item.feedback = "Exported"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            item.feedback = nil
            self.thumbnails.remove(item)
        }
    }

    /// Show a brief confirmation on the card, then remove it from the stack.
    private func flashAndRemove(_ item: CaptureItem, label: String) {
        item.feedback = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            item.feedback = nil
            self.removeItem(item)
        }
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @objc func copyLast() { if let item = thumbnails.newest { copyItem(item) } }

    @objc func saveLast() { if let item = thumbnails.newest { saveItem(item) } }

    @objc func showOnboardingAction() { showOnboarding() }

    private func showOnboarding() {
        if onboardingWindow == nil { onboardingWindow = OnboardingWindow() }
        onboardingWindow?.present()
    }

    private func openVideoEditor(for url: URL) {
        let win = VideoEditorWindow(assetURL: url, saveDirectory: saveDirectory)
        videoEditorWindows.append(win)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] note in
            guard let self, let w = note.object as? VideoEditorWindow else { return }
            self.videoEditorWindows.removeAll { $0 === w }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Recording

    @objc func recordToggle() {
        if Recorder.shared.isRecording { stopRecording() } else { presentRecordMode() }
    }

    private func presentRecordMode() {
        guard !Recorder.shared.isRecording else { return }
        if recordModePanel == nil {
            let panel = RecordModePanel()
            panel.onChoose = { [weak self] mode in self?.chooseRecordMode(mode) }
            recordModePanel = panel
        }
        recordModePanel?.present()
        updateEscState()
    }

    private func chooseRecordMode(_ mode: RecordModePanel.RecordMode) {
        recordModePanel = nil
        switch mode {
        case .screen: startRecording(region: nil, screen: NSScreen.main ?? NSScreen.screens.first!)
        case .area: presentSelection(recording: true)
        case .window: presentWindowSelection(forRecording: true)
        }
        updateEscState()
    }

    @objc func captureWindow() { presentWindowSelection(forRecording: false) }

    private func presentWindowSelection(forRecording: Bool) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && !$0.frame.isEmpty }
                await MainActor.run {
                    let overlay = WindowSelectionOverlay(windows: windows) { [weak self] w, screen in
                        guard let self else { return }
                        self.windowSelectionWindow = nil
                        if forRecording {
                            self.startRecording(window: w, screen: screen)
                        } else {
                            self.beginWindowCapture(w, screen: screen)
                        }
                        self.updateEscState()
                    }
                    self.windowSelectionWindow = overlay
                    overlay.show()
                    self.updateEscState()
                }
            } catch { self.notifyError(error) }
        }
    }

    private func beginWindowCapture(_ window: SCWindow, screen: NSScreen) {
        Task {
            do {
                let capture = try await CaptureEngine.shared.captureWindow(window, screen: screen)
                await MainActor.run { self.handleImageCapture(capture) }
            } catch { self.notifyError(error) }
        }
    }

    private func startRecording(region: CGRect?, screen: NSScreen) {
        guard !Recorder.shared.isRecording else { return }
        Task {
            do {
                try await Recorder.shared.start(region: region, screen: screen)
                await MainActor.run { self.showRecordIndicator() }
            } catch { self.notifyError(error) }
        }
    }

    private func startRecording(window: SCWindow, screen: NSScreen) {
        guard !Recorder.shared.isRecording else { return }
        Task {
            do {
                try await Recorder.shared.start(window: window, screen: screen)
                await MainActor.run { self.showRecordIndicator() }
            } catch { self.notifyError(error) }
        }
    }

    // MARK: - Esc handling

    private func updateEscState() {
        let active = selectionWindow != nil
            || windowSelectionWindow != nil
            || (recordModePanel?.isVisible ?? false)
            || Recorder.shared.isRecording
        hotkeyManager.enableEsc(active ? { [weak self] in self?.escPressed() } : nil)
    }

    private func escPressed() {
        if let w = selectionWindow { w.close(); selectionWindow = nil }
        else if let w = windowSelectionWindow { w.close(); windowSelectionWindow = nil }
        else if let m = recordModePanel, m.isVisible { m.close(); recordModePanel = nil }
        else if Recorder.shared.isRecording { stopRecording() }
        updateEscState()
    }

    @objc func stopRecording() {
        Task {
            let url = await Recorder.shared.stop()
            await MainActor.run {
                self.hideRecordIndicator()
                self.updateEscState()
                if let url { self.handleFinishedRecording(url) }
            }
        }
    }

    private func showRecordIndicator() {
        hideRecordIndicator()
        let ind = RecordIndicator()
        ind.onStop = { [weak self] in self?.stopRecording() }
        recordIndicator = ind
        ind.makeKeyAndOrderFront(nil)
        updateEscState()
    }

    private func hideRecordIndicator() {
        recordIndicator?.orderOut(nil)
        recordIndicator = nil
    }

    /// Recording finished: hold it as an unsaved card — NOTHING is written to disk
    /// until the user clicks Save (or Save Clip in the editor).
    private func handleFinishedRecording(_ url: URL) {
        hideRecordIndicator()
        let thumb = Recorder.thumbnail(for: url)
            ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            ?? NSImage()
        thumbnails.add(CaptureItem(image: thumb, videoURL: url), actions: cardActions())
    }

    // MARK: - Paths

    private func nextScreenshotURL() -> URL { saveDirectory.appendingPathComponent(CaptureNaming.screenshotName()) }
    private func nextRecordingURL() -> URL { saveDirectory.appendingPathComponent(CaptureNaming.recordingName()) }

    private func notifyError(_ error: Error) {
        NSSound.beep()
        NSLog("Sideshot error: \(error.localizedDescription)")
    }

    // MARK: - Diagnostics (DEBUG-only; never shipped)

    #if DEBUG
    private func runSelfTestIfRequested() {
        if let path = UserDefaults.standard.string(forKey: "SIDESHOT_EDITORTEST_FILE") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openVideoEditor(for: URL(fileURLWithPath: path))
            }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_MODALTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.presentRecordMode() }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_WINDOWTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.presentWindowSelection(forRecording: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    (self.windowSelectionWindow as? WindowSelectionOverlay)?.debugHoverLargest()
                }
            }
        }
        guard UserDefaults.standard.bool(forKey: "SIDESHOT_SELFTEST") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            for i in 0..<3 {
                self.thumbnails.add(CaptureItem(image: self.dummyImage(hue: CGFloat(i))), actions: self.cardActions())
            }
            self.logTest("board=\(self.thumbnails.count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                if let it = self.thumbnails.newest { self.flashAndRemove(it, label: "Copied") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.logTest("after flash+remove: board=\(self?.thumbnails.count ?? -1)")
                }
            }
        }
    }

    private func dummyImage(hue: CGFloat) -> NSImage {
        let size = NSSize(width: 400, height: 300)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(hue: hue / 3, saturation: 0.7, brightness: 0.85, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    private func logTest(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        guard let d = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/sideshot_selftest.log")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(d); try? fh.close()
        } else {
            try? d.write(to: url, options: .atomic)
        }
    }
    #endif
}