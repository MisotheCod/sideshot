import AppKit
import SwiftUI

// MARK: - Onboarding (first launch)

final class OnboardingWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 766),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        center()
        contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in self?.finish() }))
        setContentSize(NSSize(width: 560, height: 766))
    }

    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "DidShowOnboarding")
        close()
    }

    override func close() {
        UserDefaults.standard.set(true, forKey: "DidShowOnboarding")
        super.close()
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil) ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.bottom, 14)

            Text("Sideshot")
                .font(.system(size: 34, weight: .bold))

            Text("Screenshots and recordings that stay put — floating on the side, one click from copy or save.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .padding(.top, 8)

            Spacer(minLength: 26)

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(title: "Capture area", detail: "lands in the floating stack, newest at the bottom", keys: ["⌘", "⇧", "4"])
                FeatureRow(title: "Capture fullscreen", detail: "also auto-copied to your clipboard", keys: ["⌘", "⇧", "3"])
                FeatureRow(title: "Record screen", detail: "tap the red pill (or ⌘⇧5) to stop, then edit it", keys: ["⌘", "⇧", "5"])
                FeatureRow(title: "Copy or Save", detail: "hover any screenshot and the actions appear", icon: "hand.point.up.left")
            }
            .padding(.horizontal, 44)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.orange)
                    Text("Turn off macOS's screenshot shortcuts")
                        .font(.body.weight(.semibold))
                }
                Text("⌘⇧3, ⌘⇧4 and ⌘⇧5 are already used by the built-in screenshot tool. Open Keyboard Shortcuts → Screenshots and untick all three so Sideshot's hotkeys take over.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard")!)
                } label: {
                    Label("Open Keyboard Shortcuts", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.35), lineWidth: 1))
            .padding(.top, 18)
            .padding(.bottom, 8)
            .padding(.horizontal, 44)

            Spacer(minLength: 26)

            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            } label: {
                Label("Grant Screen Recording", systemImage: "rectangle.inset.filled.badge.record")
            }
            .buttonStyle(.bordered)

            Text("Required once, so Sideshot can see your screen.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)

            Button("Get Started") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 16)
                .padding(.bottom, 30)
        }
        .frame(width: 560, height: 766)
        .padding(.horizontal, 8)
    }
}

struct FeatureRow: View {
    let title: String
    let detail: String
    let keys: [String]
    let icon: String?

    init(title: String, detail: String, keys: [String] = [], icon: String? = nil) {
        self.title = title
        self.detail = detail
        self.keys = keys
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 30, height: 30)
                } else {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                        KeyCap(text: k)
                    }
                }
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A macOS-style key cap — the ⌘ and ⇧ symbols are drawn large enough to actually read.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.primary)
            .frame(width: 32, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.2), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.25), radius: 0, y: 1)
    }
}