import Foundation
import PitboxKit

/// The tab list written to `console-state.json` (in the app's private folder, mode 0600) so the terminal can bring its tabs back
/// after a restart. It holds no output, only which preset each tab ran and its folder: shells cannot survive an app
/// restart, so tabs return as fresh processes.
struct SavedState: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var preset: String
        var cwd: String?
    }

    var version = 1
    var selected = 0
    var tabs: [Tab] = []

    static func load(from url: URL, uid: uid_t = getuid()) -> SavedState? {
        let (data, trust) = SecureFile.read(url, uid: uid)
        if case .untrusted(let reason) = trust { TerminalLog.warn("terminal state ignored (\(reason))") }
        guard let data, let state = try? JSONDecoder().decode(SavedState.self, from: data), state.version == 1 else { return nil }
        return state
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        SecureFile.write(data, to: url)
    }
}

/// Turns the saved tab list into what to start.
enum RestorePlanner {
    struct Planned: Equatable {
        var preset: TerminalPreset
        /// The folder to start in: the tab's last folder for a plain shell, otherwise the preset's own.
        var cwd: String?
    }

    /// - A tab whose preset no longer exists (or is disabled) comes back as a plain shell in its last folder.
    /// - Presets with `restore: false` are not restored.
    /// - A plain shell returns in its last folder if that still exists, else in the home folder.
    /// - With nothing to restore there is one plain shell in the home folder.
    static func plan(saved: SavedState?, settings: TerminalSettings, isDirectory: (String) -> Bool) -> (sessions: [Planned], selected: Int) {
        guard let saved, !saved.tabs.isEmpty else { return ([Planned(preset: settings.defaultPreset, cwd: nil)], 0) }
        var planned: [Planned] = []
        var selectedIndex = 0
        for (index, tab) in saved.tabs.enumerated() {
            if planned.count >= settings.maxSessions { break }
            let preset = settings.preset(id: tab.preset)
            if let preset, !preset.restore { continue }
            let resolved = preset ?? settings.defaultPreset
            let folder = tab.cwd.flatMap { $0.hasPrefix("/") && isDirectory($0) ? $0 : nil }
            planned.append(Planned(preset: resolved, cwd: resolved.kind == .shell ? folder : nil))
            if index == saved.selected { selectedIndex = planned.count - 1 }
        }
        if planned.isEmpty { return ([Planned(preset: settings.defaultPreset, cwd: nil)], 0) }
        return (planned, min(max(selectedIndex, 0), planned.count - 1))
    }
}
