import ApplicationServices
import CoreGraphics
import Foundation

/// `AXWindowProviding` backed by the Accessibility API and the window server. Used only on the guard thread.
/// Every call that talks to another app is bounded by the messaging timeout, so a hung app costs at most that long.
final class AXWindowProvider: AXWindowProviding {
    typealias Window = AXUIElement

    private var timeout: Float
    private var appElements: [pid_t: AXUIElement] = [:]

    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// `_AXUIElementGetWindow`: private, but every macOS window manager has used it for a decade. Looked up at run
    /// time, so if it ever disappears the guard only loses window-number matching and falls back to frames.
    private static let getWindowFunction: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    init(messagingTimeout: Double) {
        timeout = Float(min(max(messagingTimeout, 0.05), 5))
        // The global timeout covers every element this process creates, including windows returned by apps.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }

    func setMessagingTimeout(_ seconds: Double) {
        timeout = Float(min(max(seconds, 0.05), 5))
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
        for element in appElements.values { AXUIElementSetMessagingTimeout(element, timeout) }
    }

    /// The (cached) application element, with the messaging timeout applied.
    func appElement(_ pid: pid_t) -> AXUIElement {
        if let element = appElements[pid] { return element }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        appElements[pid] = element
        return element
    }

    func forgetApp(_ pid: pid_t) { appElements[pid] = nil }

    // MARK: - AXWindowProviding

    func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(AXParsing.onScreenWindow(from:))
    }

    func windows(ofPID pid: pid_t) -> Result<[AXUIElement], AXFailure> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement(pid), kAXWindowsAttribute as CFString, &value)
        if error == .noValue { return .success([]) }
        guard error == .success else { return .failure(AXFailure(error)) }
        return .success((value as? [AXUIElement]) ?? [])
    }

    func pid(of window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(window, &pid) == .success && pid > 0 ? pid : nil
    }

    func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let function = Self.getWindowFunction else { return nil }
        var id: CGWindowID = 0
        return function(window, &id) == .success && id != 0 ? id : nil
    }

    func info(of window: AXUIElement) -> Result<WindowInfo, AXFailure> {
        guard let pid = pid(of: window) else { return .failure(.invalidElement) }
        switch copyValues(AXParsing.infoAttributes, of: window) {
        case .failure(let failure): return .failure(failure)
        case .success(let values):
            guard let info = AXParsing.windowInfo(pid: pid, values: values) else { return .failure(.unsupported) }
            return .success(info)
        }
    }

    func capabilities(of window: AXUIElement) -> Result<WindowCapabilities, AXFailure> {
        let resizable: Bool
        switch settable(kAXSizeAttribute, of: window) {
        case .success(let value): resizable = value
        case .failure(let failure): return .failure(failure)
        }
        return settable(kAXPositionAttribute, of: window).map { WindowCapabilities(resizable: resizable, movable: $0) }
    }

    func serverState(ofWindowID id: CGWindowID) -> ServerWindowState? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first else { return nil }
        return AXParsing.serverState(from: entry)
    }

    func setFrame(_ target: CGRect, of window: AXUIElement, from current: CGRect) -> Result<CGRect, AXFailure> {
        let resize = abs(target.width - current.width) > 0.5 || abs(target.height - current.height) > 0.5
        let move = abs(target.minX - current.minX) > 0.5 || abs(target.minY - current.minY) > 0.5
        // Size first, then position: corrections only shrink, so every intermediate frame stays inside the old one.
        if resize, let failure = set(size: target.size, of: window) { return .failure(failure) }
        if move, let failure = set(origin: target.origin, of: window) { return .failure(failure) }
        var actual: CGRect
        switch frame(of: window) {
        case .success(let frame): actual = frame
        case .failure(let failure): return .failure(failure)
        }
        // Some apps clamp the size to the display the window was on; after a move, apply the size once more.
        if resize, move, abs(actual.width - target.width) > 0.5, set(size: target.size, of: window) == nil,
           case .success(let again) = frame(of: window) {
            actual = again
        }
        return .success(actual)
    }

    func enableManualAccessibility(pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(appElement(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    // MARK: - Helpers

    private func frame(of window: AXUIElement) -> Result<CGRect, AXFailure> {
        switch copyValues(AXParsing.frameAttributes, of: window) {
        case .failure(let failure): return .failure(failure)
        case .success(let values):
            guard let frame = AXParsing.frame(values: values) else { return .failure(.unsupported) }
            return .success(frame)
        }
    }

    private func copyValues(_ attributes: [String], of element: AXUIElement) -> Result<[AnyObject], AXFailure> {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
                                                           AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success else { return .failure(AXFailure(error)) }
        guard let list = values as? [AnyObject] else { return .failure(.unsupported) }
        return .success(list)
    }

    /// An attribute the window does not have is "not settable"; a timeout (`kAXErrorCannotComplete`, "often due to a
    /// timeout" per the header) or a vanished window is a failure the engine backs off from or forgets.
    private func settable(_ attribute: String, of element: AXUIElement) -> Result<Bool, AXFailure> {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if error == .success { return .success(settable.boolValue) }
        let failure = AXFailure(error)
        return failure == .unsupported ? .success(false) : .failure(failure)
    }

    private func set(size: CGSize, of window: AXUIElement) -> AXFailure? {
        var value = size
        guard let ax = AXValueCreate(.cgSize, &value) else { return .other(-1) }
        let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, ax)
        return error == .success ? nil : AXFailure(error)
    }

    private func set(origin: CGPoint, of window: AXUIElement) -> AXFailure? {
        var value = origin
        guard let ax = AXValueCreate(.cgPoint, &value) else { return .other(-1) }
        let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, ax)
        return error == .success ? nil : AXFailure(error)
    }
}
