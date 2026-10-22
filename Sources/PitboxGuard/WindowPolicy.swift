import CoreGraphics
import Darwin

/// Which windows the guard manages. Pure, so it is unit-tested directly.
enum WindowPolicy {
    /// Why `info` must be left alone, or nil if the guard may correct it.
    ///
    /// Managed: role `AXWindow` with a subrole in `options.managedSubroles` (standard windows and dialogs by default).
    /// Left alone: minimized windows, native full-screen windows (`AXFullScreen`), windows covering their whole
    /// display (non-native full screen, presentations, kiosks), empty frames and windows on no display.
    static func ineligibility(of info: WindowInfo, options: GuardOptions, displays: [GuardDisplay]) -> String? {
        guard info.role == "AXWindow" else { return "role \(info.role ?? "none")" }
        guard let subrole = info.subrole, options.managedSubroles.contains(subrole) else {
            return "subrole \(info.subrole ?? "none")"
        }
        if info.minimized { return "minimized" }
        if info.fullScreen { return "full screen" }
        guard Placement.isUsable(info.frame) else { return "empty frame" }
        guard let home = Placement.homeDisplay(for: info.frame, displays: displays) else { return "on no display" }
        if Placement.coversDisplay(info.frame, home) { return "covers its display" }
        return nil
    }

    /// Whether the guard manages `app`'s windows at all: only regular apps (activation policy `.regular`), never the
    /// guard's own process, never an exempt bundle. Accessory (`LSUIElement`) and background apps are never managed,
    /// so two accessory apps whose guards sit side by side (Pitbox docked beside a host app's strip) never move each
    /// other's panels. Windows off layer 0 are skipped as well (`GuardEngine.isCandidate`, `evaluate`).
    static func manages(_ app: AppSnapshot, ownPID: pid_t, options: GuardOptions) -> Bool {
        let exempt = app.bundleID.map { options.exemptBundleIDs.contains($0) } ?? false
        return app.isRegular && app.pid != ownPID && !exempt
    }
}

/// A frame rounded to whole points, tagged with its owner, for matching window-server and Accessibility frames.
struct FrameKey: Hashable {
    let pid: pid_t
    let x: Int, y: Int, width: Int, height: Int

    init(pid: pid_t, frame: CGRect) {
        self.pid = pid
        x = Self.whole(frame.minX); y = Self.whole(frame.minY)
        width = Self.whole(frame.width); height = Self.whole(frame.height)
    }

    /// Rounds without trapping on NaN or huge values.
    static func whole(_ v: CGFloat) -> Int {
        guard v.isFinite else { return 0 }
        return Int(min(max(v, -1e9), 1e9).rounded())
    }
}

/// A window-server window the reconcile pass already judged, valid while it keeps the same number and bounds.
struct SettleKey: Hashable {
    let windowID: CGWindowID
    let frame: FrameKey

    init(_ window: OnScreenWindow) {
        windowID = window.windowID
        frame = FrameKey(pid: window.pid, frame: window.bounds)
    }
}

/// Compact frame text for logs: "x,y wxh".
func describe(_ r: CGRect) -> String {
    "\(FrameKey.whole(r.minX)),\(FrameKey.whole(r.minY)) \(FrameKey.whole(r.width))x\(FrameKey.whole(r.height))"
}
