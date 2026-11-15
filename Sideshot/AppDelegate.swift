import AppKit
import Carbon
import ScreenCaptureKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, SPUStandardUserDriverDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let thumbnails = ThumbnailManager()
    private var updaterController: SPUStandardUpdaterController?
    /// Set when Sparkle finds an update while Sideshot isn't frontmost, so we can
    /// surface it in the menu bar instead of popping an alert nobody is looking at.
    private var gentleUpdateVersion: String?
    private var selectionWindow: SelectionOverlayWindow?
    private var recordingSelection = false
    private var recordIndicator: RecordIndicator?
    private var onboardingWindow: OnboardingWindow?
    private var annotateWindow: AnnotateWindow?
    private var videoEditorWindows: [VideoEditorWindow] = []
    private var capturePicker: CapturePickerPanel?
    private var recordingBorder: RecordingBorderWindow?
    private var recordingBorderTimer: Timer?
    private var recordingWindowID: CGWindowID?
    private var lastCaptureError: String?
    private var needsScreenPermission = false
    private var windowSelectionWindow: NSWindow?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: a menu-bar hotkey app must never run twice.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cam.sideshot")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }

        NSApp.setActivationPolicy(.accessory)
        // Make sure the icon the system (and Sparkle's update window) shows is
        // ours. NSImageNameApplicationIcon reads this, and for an accessory
        // (menu-bar only) app the bundle icon isn't always picked up on its own.
        NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        Recorder.shared.onFinished = { [weak self] url in
            Task { @MainActor in self?.handleFinishedRecording(url) }
        }
        Recorder.shared.onError = { [weak self] error in
            Task { @MainActor in self?.notifyError(error) }
        }
        setupStatusItem()
        registerHotkeys()
        // Sparkle: background update checks, plus a manual menu item.
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                        updaterDelegate: nil,
                                                        userDriverDelegate: self)
        if !UserDefaults.standard.bool(forKey: "DidShowOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showOnboarding() }
        }
        #if DEBUG
        runSelfTestIfRequested()
        #endif
    }

    // MARK: - Menu

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - Sparkle gentle reminders
    //
    // Sideshot is an LSUIElement menu-bar app: a scheduled-update alert can open
    // behind whatever the user is doing and never be seen. Sparkle asks the
    // delegate to "gently" handle those instead, so we put a row in the menu bar.

    // NOTE: this is a readonly @property in the ObjC protocol, not a method.
    // Declaring it as `func` compiles but never satisfies the protocol, so
    // Sparkle keeps reporting "does not implement gentle reminders".
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Sideshot is a menu-bar utility: it has no window to anchor an alert to
        // and is never genuinely "frontmost" in the way a document app is, so
        // always take the gentle path for scheduled checks. A manual
        // "Check for Updates…" is not a scheduled update and still shows the
        // standard UI.
        return false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        gentleUpdateVersion = update.displayVersionString
        refreshMenu()
        #if DEBUG
        let titles = (statusItem.menu?.items ?? []).map { $0.isSeparatorItem ? "---" : $0.title }
        NSLog("SIDESHOT_GENTLE_REMINDER version=%@ menu=%@", update.displayVersionString, titles.joined(separator: " | "))
        #endif
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearGentleReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearGentleReminder()
    }

    private func clearGentleReminder() {
        guard gentleUpdateVersion != nil else { return }
        gentleUpdateVersion = nil
        refreshMenu()
    }

    /// Rebuild the menu every time it opens: version and permission state change at
    /// runtime, and a menu built once at launch shows stale (wrong) information.
    private func refreshMenu() {
        // Intentionally empty — the menu is constructed on open.
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Sideshot")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Seed it: an empty menu can fail to open before the delegate is consulted.
        menuNeedsUpdate(menu)
    }

    /// Rebuild the item list every time the menu opens, so the version and the
    /// Screen Recording state are never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = buildMenu()
        let items = fresh.items
        for i in items { fresh.removeItem(i) }
        for i in items { menu.addItem(i) }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        needsScreenPermission = !CGPreflightScreenCaptureAccess()

        func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            return it
        }

        // Always show the running version and whether capture will actually work —
        // otherwise there is no way to tell which build is installed.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let header = NSMenuItem(title: "Sideshot \(version) (\(build))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let perm = NSMenuItem(title: needsScreenPermission
                              ? "Screen Recording: NOT granted"
                              : "Screen Recording: granted",
                              action: nil, keyEquivalent: "")
        perm.isEnabled = false
        menu.addItem(perm)
        menu.addItem(.separator())

        if let v = gentleUpdateVersion {
            menu.addItem(item("Sideshot \(v) is available…", #selector(checkForUpdates)))
            menu.addItem(.separator())
        }

        if needsScreenPermission {
            menu.addItem(item("Screen Recording permission needed…", #selector(openScreenRecordingSettings)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Capture Area", #selector(captureArea), key: "4", mods: [.command, .shift]))
        menu.addItem(item("Capture Fullscreen", #selector(captureFullscreen), key: "3", mods: [.command, .shift]))
        menu.addItem(item("Capture Window", #selector(captureWindow)))
        menu.addItem(item("Capture Scrolling Page", #selector(captureScrollPage), key: "6", mods: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Capture or Record…", #selector(recordToggle), key: "5", mods: [.command, .shift]))
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
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
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
        hotkeyManager.register(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey), id: 4) { [weak self] in
            self?.captureScrollPage()
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
        if Recorder.shared.isRecording { stopRecording() } else { presentCapturePicker() }
    }

    /// ⌘⇧5 — one picker for everything: screenshot or record, then screen / window / area.
    private func presentCapturePicker() {
        guard !Recorder.shared.isRecording else { return }
        if capturePicker == nil {
            let panel = CapturePickerPanel()
            panel.onChoose = { [weak self] kind, target in self?.chooseCapture(kind, target) }
            capturePicker = panel
        }
        capturePicker?.present()
        updateEscState()
    }

    private func chooseCapture(_ kind: CapturePickerPanel.Kind, _ target: CapturePickerPanel.Target) {
        capturePicker = nil
        switch (kind, target) {
        case (.screenshot, .screen): captureFullscreen()
        case (.screenshot, .window): presentWindowSelection(forRecording: false)
        case (.screenshot, .area):   presentSelection(recording: false)
        case (.record, .screen):     startRecording(region: nil, screen: NSScreen.main ?? NSScreen.screens.first!)
        case (.record, .window):     presentWindowSelection(forRecording: true)
        case (.record, .area):       presentSelection(recording: true)
        }
        updateEscState()
    }

    @objc func captureWindow() { presentWindowSelection(forRecording: false) }

    @objc func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// ⌘⇧6 — pick a window, then scroll it top to bottom and stitch the result.
    @objc func captureScrollPage() { presentWindowSelection(forScroll: true) }

    private func presentWindowSelection(forRecording: Bool = false, forScroll: Bool = false) {
        // Tear down any picker still on screen first — otherwise a previous overlay
        // keeps highlighting windows underneath the new one.
        windowSelectionWindow?.orderOut(nil)
        windowSelectionWindow?.close()
        windowSelectionWindow = nil
        capturePicker?.close()
        capturePicker = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && !$0.frame.isEmpty }
                await MainActor.run {
                    let overlay = WindowSelectionOverlay(windows: windows) { [weak self] w, screen in
                        guard let self else { return }
                        self.windowSelectionWindow?.orderOut(nil)
                        self.windowSelectionWindow = nil
                        if forScroll {
                            self.beginScrollCapture(w, screen: screen)
                        } else if forRecording {
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

    private func beginScrollCapture(_ window: SCWindow, screen: NSScreen) {
        guard !ScrollCapture.shared.isRunning else { return }
        let hud = ScrollHUD()
        hud.show()
        Task {
            do {
                let image = try await ScrollCapture.shared.capture(window: window, screen: screen) { px in
                    DispatchQueue.main.async { hud.update(pixels: px) }
                }
                await MainActor.run {
                    hud.close()
                    self.handleImageCapture(Capture(image: image,
                                                    pointSize: CGSize(width: image.width, height: image.height)))
                }
            } catch {
                await MainActor.run {
                    hud.close()
                    self.notifyError(error)
                }
            }
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
                // Create the border first so the recorder can exclude it from the stream.
                await MainActor.run {
                    if let r = region {
                        // Selection rect is screen-local with a top-left origin.
                        let rect = NSRect(x: screen.frame.minX + r.minX,
                                          y: screen.frame.maxY - r.maxY,
                                          width: r.width, height: r.height)
                        self.showRecordingBorder(rect: rect)
                    } else {
                        self.showRecordingBorder(rect: screen.frame.insetBy(dx: 2, dy: 2))
                    }
                }
                try await Recorder.shared.start(region: region, screen: screen)
                await MainActor.run {
                    self.showRecordIndicator(source: region == nil ? "Screen" : "Area")
                }
            } catch { self.notifyError(error) }
        }
    }

    private func startRecording(window: SCWindow, screen: NSScreen) {
        guard !Recorder.shared.isRecording else { return }
        Task {
            do {
                try await Recorder.shared.start(window: window, screen: screen)
                await MainActor.run {
                    self.showRecordIndicator(source: "Window")
                    self.recordingWindowID = window.windowID
                    self.showRecordingBorder(rect: appKitRect(fromCaptureRect: window.frame))
                    self.startBorderFollow()
                }
            } catch { self.notifyError(error) }
        }
    }

    // MARK: - Esc handling

    private func updateEscState() {
        let active = selectionWindow != nil
            || windowSelectionWindow != nil
            || (capturePicker?.isVisible ?? false)
            || Recorder.shared.isRecording
        hotkeyManager.enableEsc(active ? { [weak self] in self?.escPressed() } : nil)
    }

    private func escPressed() {
        if let w = selectionWindow { w.close(); selectionWindow = nil }
        else if let w = windowSelectionWindow { w.close(); windowSelectionWindow = nil }
        else if let m = capturePicker, m.isVisible { m.close(); capturePicker = nil }
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

    /// Draw a pulsing red frame around exactly what is being recorded.
    private func showRecordingBorder(rect: NSRect) {
        hideRecordingBorder()
        guard rect.width > 4, rect.height > 4 else { return }
        let border = RecordingBorderWindow(rect: rect)
        recordingBorder = border
        border.orderFrontRegardless()
    }

    private func hideRecordingBorder() {
        recordingBorderTimer?.invalidate()
        recordingBorderTimer = nil
        recordingWindowID = nil
        recordingBorder?.orderOut(nil)
        recordingBorder?.close()
        recordingBorder = nil
    }

    /// Keep the border glued to the window if the user moves or resizes it mid-recording.
    private func startBorderFollow() {
        recordingBorderTimer?.invalidate()
        recordingBorderTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, let id = self.recordingWindowID else { return }
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
            guard let info = list?.first,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  w > 4, h > 4
            else { return }
            self.recordingBorder?.move(to: appKitRect(fromCaptureRect: CGRect(x: x, y: y, width: w, height: h)))
        }
    }

    private func showRecordIndicator(source: String) {
        hideRecordIndicator()
        let ind = RecordIndicator(source: source)
        ind.onStop = { [weak self] in self?.stopRecording() }
        recordIndicator = ind
        ind.show()
        // Red dot in the menu bar too, so there's always a sign it's recording even
        // if the floating pill is hidden behind a full-screen window.
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill",
                                           accessibilityDescription: "Recording")
        statusItem.button?.contentTintColor = .systemRed
        updateEscState()
    }

    private func hideRecordIndicator() {
        hideRecordingBorder()
        recordIndicator?.orderOut(nil)
        recordIndicator = nil
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "Sideshot")
        statusItem.button?.contentTintColor = nil
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
        lastCaptureError = error.localizedDescription

        // Automated diagnostics must not block on a modal alert.
        if UserDefaults.standard.bool(forKey: "SIDESHOT_REALCLICKSHOT")
            || UserDefaults.standard.bool(forKey: "SIDESHOT_REALCLICKTEST")
            || UserDefaults.standard.bool(forKey: "SIDESHOT_SELFTEST") { return }

        // A beep plus a console line is invisible in practice: the capture just seems
        // to do nothing. Screen Recording permission is revoked by every rebuild, so
        // tell the user exactly that instead of failing silently.
        let alert = NSAlert()
        alert.messageText = "Sideshot couldn't capture that"
        alert.informativeText = """
        \(error.localizedDescription)

        This is usually Screen Recording permission. Open System Settings → Privacy & Security → Screen & System Audio Recording and make sure Sideshot is switched on, then try again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: - Diagnostics (DEBUG-only; never shipped)

    #if DEBUG
    private func runSelfTestIfRequested() {
        if UserDefaults.standard.bool(forKey: "SIDESHOT_SCROLLTEST") {
            _ = ScrollCapture.debugSelfTest()
            NSApp.terminate(nil)
            return
        }
        if let path = UserDefaults.standard.string(forKey: "SIDESHOT_EDITORTEST_FILE") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openVideoEditor(for: URL(fileURLWithPath: path))
            }
        }
        if let path = UserDefaults.standard.string(forKey: "SIDESHOT_ANNOTATETEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let img = NSImage(contentsOfFile: path) else { return }
                self.openAnnotator(for: img)
            }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_MODALTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.presentCapturePicker() }
        }
        if let out = UserDefaults.standard.string(forKey: "SIDESHOT_PICKERSHOT") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                for (kind, suffix) in [(CapturePickerPanel.Kind.screenshot, "shot"),
                                       (CapturePickerPanel.Kind.record, "rec")] {
                    let view = CapturePickerView(initial: kind, onChoose: { _, _ in }, onCancel: {})
                    let hosting = NSHostingView(rootView: view)
                    hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 320)
                    hosting.layoutSubtreeIfNeeded()
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let path = out.replacingOccurrences(of: ".png", with: "-\(suffix).png")
                        try? data.write(to: URL(fileURLWithPath: path))
                        NSLog("SIDESHOT_PICKERSHOT wrote %@", path)
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if let out = UserDefaults.standard.string(forKey: "SIDESHOT_BORDERSHOT") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let v = RecordingBorderView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                    NSLog("SIDESHOT_BORDERSHOT no rep"); NSApp.terminate(nil); return
                }
                v.cacheDisplay(in: v.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: out))
                    NSLog("SIDESHOT_BORDERSHOT wrote %@", out)
                }
                NSApp.terminate(nil)
            }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_BORDERTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let screen = NSScreen.main ?? NSScreen.screens.first!
                self.showRecordingBorder(rect: screen.frame.insetBy(dx: 2, dy: 2))
                Task {
                    do {
                        try await Recorder.shared.start(region: nil, screen: screen)
                        await MainActor.run { self.showRecordIndicator(source: "Screen") }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        let url = await Recorder.shared.stop()
                        await MainActor.run { self.hideRecordIndicator() }
                        if let url {
                            let dest = URL(fileURLWithPath: "/tmp/bordertest.mp4")
                            try? FileManager.default.removeItem(at: dest)
                            try? FileManager.default.copyItem(at: url, to: dest)
                            NSLog("SIDESHOT_BORDERTEST wrote %@", dest.path)
                        } else {
                            NSLog("SIDESHOT_BORDERTEST no url")
                        }
                    } catch {
                        NSLog("SIDESHOT_BORDERTEST failed %@", error.localizedDescription)
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_REALCLICKSHOT") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let before = self.thumbnails.count
                self.presentWindowSelection(forRecording: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let ov = self.windowSelectionWindow,
                          let view = ov.contentView as? WindowSelectionView,
                          let target = view.largestWindow else {
                        NSLog("SIDESHOT_REALCLICKSHOT no overlay"); NSApp.terminate(nil); return
                    }
                    let pt = CGPoint(x: target.frame.midX, y: target.frame.midY)
                    let src = CGEventSource(stateID: .hidSystemState)
                    CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(80_000)
                    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(80_000)
                    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        NSLog("SIDESHOT_REALCLICKSHOT cardsBefore=%d cardsAfter=%d error=%@",
                              before, self.thumbnails.count,
                              self.lastCaptureError ?? "none")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_REALCLICKTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.presentWindowSelection(forRecording: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let ov = self.windowSelectionWindow,
                          let view = ov.contentView as? WindowSelectionView else {
                        NSLog("SIDESHOT_REALCLICKTEST no overlay"); NSApp.terminate(nil); return
                    }
                    guard let target = view.largestWindow else {
                        NSLog("SIDESHOT_REALCLICKTEST no window"); NSApp.terminate(nil); return
                    }
                    let pt = CGPoint(x: target.frame.midX, y: target.frame.midY)
                    NSLog("SIDESHOT_REALCLICKTEST posting click at %.0f,%.0f", pt.x, pt.y)
                    let src = CGEventSource(stateID: .hidSystemState)
                    CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(80_000)
                    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(80_000)
                    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        NSLog("SIDESHOT_REALCLICKTEST overlayVisible=%@ recording=%@ indicatorVisible=%@ border=%@",
                              (self.windowSelectionWindow?.isVisible ?? false) ? "YES" : "NO",
                              Recorder.shared.isRecording ? "YES" : "NO",
                              (self.recordIndicator?.isVisible ?? false) ? "YES" : "NO",
                              (self.recordingBorder?.isVisible ?? false) ? "YES" : "NO")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "SIDESHOT_CLICKTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.presentWindowSelection(forRecording: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    (self.windowSelectionWindow as? WindowSelectionOverlay)?.debugClickLargest()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        let visible = self.windowSelectionWindow?.isVisible ?? false
                        NSLog("SIDESHOT_CLICKTEST overlayVisible=%@ recording=%@ indicator=%@ indicatorVisible=%@",
                              visible ? "YES" : "NO",
                              Recorder.shared.isRecording ? "YES" : "NO",
                              self.recordIndicator == nil ? "NO" : "YES",
                              (self.recordIndicator?.isVisible ?? false) ? "YES" : "NO")
                        NSApp.terminate(nil)
                    }
                }
            }
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