import AppKit

/// The application delegate: builds the app at launch and takes it down in order at quit (`PitboxApp`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: PitboxApp?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = PitboxApp()
        self.app = app
        app.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.terminate()
    }

    /// An accessory app has no windows to wait for: closing the settings window never quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
