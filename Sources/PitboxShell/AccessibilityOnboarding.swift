import AppKit
import ApplicationServices
import SwiftUI
import PitboxKit

/// The app's file name as Finder and the + file picker show it ("Pitbox.app"); the list itself shows the display name.
private let appFileName: String = {
    let url = Bundle.main.bundleURL
    return url.pathExtension == "app" ? url.lastPathComponent : "\(AppIdentity.displayName).app"
}()

/// Small native window: what the Accessibility grant is for (pit stops and bringing windows back on track, matching
/// pop-outs by title, desk tags, drag-to-pit and the window guard; the monitors and the Ready list work without it),
/// the live trusted state, and a button that opens
/// System Settings > Privacy & Security > Accessibility. Polls the trust state (once a second, only while visible) and
/// also reacts to the system's accessibility-change notification. Never changes any setting itself.
@MainActor
public final class AccessibilityOnboarding: NSObject, NSWindowDelegate {
    /// System Settings deep link to the Accessibility list.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// Called once when the app becomes trusted while the window is open (start the window guard and the window
    /// features here).
    public var onTrusted: (() -> Void)?
    /// Called when the window closes.
    public var onClose: (() -> Void)?
    /// True while the window is on screen.
    public var isShowing: Bool { window?.isVisible ?? false }

    private let isTrusted: () -> Bool
    private let model = OnboardingModel()
    private var window: NSWindow?
    private var timer: Timer?
    private var axObserver: NSObjectProtocol?
    private var reportedTrusted = false

    /// `isTrusted` defaults to `AXIsProcessTrusted()`; the app may pass the window guard's check instead.
    public init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
        super.init()
        model.openSettings = { Self.openAccessibilitySettings() }
        model.revealApp = { Self.revealAppInFinder() }
        model.dismiss = { [weak self] in self?.close() }
    }

    /// Shows (or brings forward) the window.
    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        refresh()
        startWatching()
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Closes the window (polling stops).
    public func close() {
        window?.close()
    }

    /// Opens System Settings at Privacy & Security > Accessibility.
    public static func openAccessibilitySettings() {
        guard let url = settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Selects the running app bundle in Finder, so it can be dragged into the Accessibility list.
    public static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        stopWatching()
        onClose?()
    }

    // MARK: Private

    private func makeWindow() -> NSWindow {
        let host = NSHostingView(rootView: OnboardingView(model: model))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 360),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.displayName) Accessibility"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.contentView = host
        window.delegate = self
        return window
    }

    private func startWatching() {
        if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if axObserver == nil {
            axObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
                // The trust database is updated just after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let axObserver { DistributedNotificationCenter.default().removeObserver(axObserver) }
        axObserver = nil
    }

    private func refresh() {
        let trusted = isTrusted()
        if model.trusted != trusted { model.trusted = trusted }
        if trusted, !reportedTrusted {
            reportedTrusted = true
            Log.info("accessibility granted", "shell")
            window?.orderFrontRegardless()
            onTrusted?()
        } else if !trusted {
            reportedTrusted = false
        }
    }
}

final class OnboardingModel: ObservableObject {
    @Published var trusted = false
    var openSettings: () -> Void = {}
    var revealApp: () -> Void = {}
    var dismiss: () -> Void = {}
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(nsColor: PitboxTheme.accent.nsColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pit stops and the window guard").font(.title2.weight(.semibold))
                    Text("\(AppIdentity.displayName) needs Accessibility access").foregroundStyle(.secondary)
                }
            }
            Text("\(AppIdentity.displayName) uses it to send Claude’s pop-out windows into the pit and bring them back on "
                 + "track, to match pop-outs to their sessions by window title, for desk tags and drag-to-pit, and for "
                 + "the window guard, which moves or resizes other apps’ windows out of the block like a window manager. "
                 + "macOS allows that only with Accessibility access.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Without it, the monitors and the Ready list still work.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("It uses window positions and sizes, and the titles of Claude’s windows only: never window contents or "
                  + "what you type.", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusRow
            if !model.trusted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click Open System Settings.")
                    // The list shows the app's display name; the file picker shows the file name (`appFileName`).
                    Text("2. Switch on \(AppIdentity.displayName) in the list. If it is missing, click + and choose \(appFileName).")
                    Text("3. Rebuilt the app? Remove \(AppIdentity.displayName) from the list and add it again.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack {
                if !model.trusted {
                    Button("Show \(appFileName) in Finder") { model.revealApp() }
                        .buttonStyle(.link)
                }
                Spacer()
                if model.trusted {
                    Button("Done") { model.dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { model.dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open System Settings") { model.openSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 500)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.trusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(model.trusted ? Color.green : Color.orange)
            Text(model.trusted ? "Access granted. Pit stops and the window guard are on."
                               : "Not granted yet. This updates by itself.")
                .fontWeight(.medium)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}
