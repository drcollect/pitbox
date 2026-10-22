import AppKit

// Pitbox's entry point: an accessory app (no Dock icon and no app menu; the bundle's Info.plist also says LSUIElement).
// `AppDelegate` hands the launch to `PitboxApp`, the composition root. Top-level code runs on the main thread; `run()`
// blocks until the app quits, which keeps `delegate` alive.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
