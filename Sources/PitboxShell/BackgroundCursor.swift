import AppKit
import PitboxKit

/// Lets the panel set the mouse cursor (resize cursors, I-beams and link cursors in the block) while another app is
/// active, which is almost always: the panel never activates the app. The window server ignores cursor changes
/// from background apps unless the connection property "SetsCursorInBackground" is set. That property is private
/// (widely used by utilities), so it is looked up at runtime: if it ever disappears, nothing breaks, the panel just
/// keeps the arrow cursor. Measured on macOS 26.5: without it the cursor stays the arrow.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> UInt32
    private typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32

    @MainActor private static var enabled = false

    /// Idempotent. Returns whether the property is set.
    @MainActor
    @discardableResult
    static func enable() -> Bool {
        if enabled { return true }
        let handle = dlopen(nil, RTLD_NOW)
        defer { if let handle { dlclose(handle) } }
        guard let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            Log.warn("background cursor: window server symbols unavailable", "shell")
            return false
        }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let status = unsafeBitCast(setSymbol, to: SetProperty.self)(connection, connection,
                                                                  "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        enabled = status == 0
        if !enabled { Log.warn("background cursor: property refused (\(status))", "shell") }
        return enabled
    }
}
