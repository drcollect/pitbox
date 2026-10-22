import Foundation

/// Well-known locations. Everything the app writes lives under `appSupport` (private, 0700), `logsDir` and
/// `cachesDir`; nothing is written anywhere else without a click.
public enum Paths {
    /// `~/Library/Application Support/Pitbox`, or the folder named by the `PITBOX_APP_SUPPORT` environment variable.
    /// Tests set the variable to a scratch folder (`scripts/test.sh` does) so they never write into the app's real
    /// state. Keep the path short: the dock socket lives in it (`sockaddr_un` limits paths to 104 bytes).
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pitbox", isDirectory: true)
    }

    /// `~/Library/Logs/Pitbox`; `<appSupport>/logs` while `PITBOX_APP_SUPPORT` is set (tests).
    public static var logsDir: URL {
        if let override = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], !override.isEmpty {
            return appSupport.appendingPathComponent("logs", isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Pitbox", isDirectory: true)
    }

    /// `~/Library/Caches/Pitbox` (Fetch staging, the web preview's rule list); `<appSupport>/caches` while
    /// `PITBOX_APP_SUPPORT` is set (tests).
    public static var cachesDir: URL {
        if let override = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], !override.isEmpty {
            return appSupport.appendingPathComponent("caches", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pitbox", isDirectory: true)
    }

    /// The settings file (`settings.json`, docs/SETTINGS.md).
    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }

    /// The dock link's socket (docs/DOCK_PROTOCOL.md). Pitbox listens; a dock host connects.
    public static var dockSocketPath: String { appSupport.appendingPathComponent("dock.sock").path }

    /// Creates `appSupport` and `logsDir` (private: mode 0700), tightening folders that already existed.
    public static func ensureDirs() throws {
        let fm = FileManager.default
        for dir in [appSupport, logsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
