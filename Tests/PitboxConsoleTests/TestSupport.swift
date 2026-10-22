import Foundation
import Testing
@testable import PitboxConsole

/// A private scratch folder (mode 0700) removed when the value goes away. Tests never touch the real
/// `~/Library/Application Support/Pitbox`.
final class TempDir {
    let url: URL
    init() {
        TerminalLog.enabled = false   // tests must not add lines (or deliberate warnings) to the app's real log file
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pitbox-console-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var paths: TerminalPaths { TerminalPaths(directory: url) }

    @discardableResult
    func write(_ name: String, _ text: String, mode: mode_t = 0o600) -> URL {
        let file = url.appendingPathComponent(name)
        try? Data(text.utf8).write(to: file)
        chmod(file.path, mode)
        return file
    }
}

/// The console's settings from JSON, as `TerminalSettings.parse` reads it; nil (or text that is not a JSON object)
/// gives the defaults.
func testSettings(_ json: String?) -> TerminalSettings {
    guard let json else { return .standard }
    return TerminalSettings.parse(Data(json.utf8))?.settings ?? .standard
}

/// An environment with every input fixed, for tests that must not depend on this Mac.
func fixtureEnvironment(parent: [String: String] = [:], accountShell: String? = "/bin/zsh",
                        executables: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh"],
                        directories: Set<String> = ["/Users/tester", "/tmp", "/Users/tester/proj"],
                        locales: Set<String> = ["en_US.UTF-8", "de_DE.UTF-8"],
                        language: String? = "en", region: String? = "US") -> TerminalEnvironment {
    TerminalEnvironment(parent: parent, home: "/Users/tester", userName: "tester", accountShell: accountShell,
                        languageCode: language, regionCode: region, appVersion: "9.9",
                        isExecutable: { executables.contains($0) }, localeExists: { locales.contains($0) },
                        isDirectory: { directories.contains($0) })
}

/// Polls `condition` on the main actor until it holds, giving it `timeout` seconds' worth of polls (10 ms apart).
///
/// The budget is counted in polls the main actor actually ran, not in wall-clock time. About 200 main-actor tests share
/// the main queue with the pty's output delivery, process exits and run-loop timers; on a loaded Mac that queue falls
/// seconds behind, and a wall-clock deadline then expires while the awaited output sits in the queue right behind the
/// final check (the flake of the console's tests under load). Counting polls lets the delivery run between two checks;
/// each test's `.timeLimit` still bounds a real hang.
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<max(1, Int((timeout / 0.01).rounded(.up))) {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

extension ConsoleHost {
    /// Tests: "Open a terminal on <alias>" and its answer (the SSH config is read off the main thread).
    @MainActor func openServerTab(alias: String) async -> String? {
        await withCheckedContinuation { continuation in
            openServerTab(alias: alias) { continuation.resume(returning: $0) }
        }
    }
}
