import Foundation
import PitboxKit

// What the settings window's pop-ups list and the file-only keys it shows (`SettingsWindowModel`).
extension SettingsWindowModel {
    /// The entries of a pop-up field, exactly one of them selected.
    public func choices(for field: SettingsField) -> [SettingsChoice] {
        let code = settings
        switch field {
        case .columns:
            return [2, 1].map { SettingsChoice(title: "\($0)", change: .columns($0), selected: code.columns == $0) }
        case .edge:
            return [(Edge.right, "Right"), (.left, "Left")].map {
                SettingsChoice(title: $0.1, change: .edge($0.0), selected: code.edge == $0.0)
            }
        case .display:
            return displayChoices()
        case .look:
            return [(CodeSettings.Look.monitors, "Monitors"), (.rows, "Slim rows")].map {
                SettingsChoice(title: $0.1, change: .look($0.0), selected: code.look == $0.0)
            }
        case .deskWindows:
            return [(CodeSettings.DeskWindows.tags, "Desk tags only"), (.monitors, "Monitors too")].map {
                SettingsChoice(title: $0.1, change: .deskWindows($0.0), selected: code.deskWindows == $0.0)
            }
        case .peekDelay:
            return Self.withCustom([(0.4, "After 0.4 s"), (1.2, "After 1.2 s"), (0, "Off")], current: code.peekDelaySeconds,
                                   change: { .peekDelaySeconds($0) },
                                   custom: { "After \(Self.number($0)) s" })
        case .ready:
            return Self.withCustom([(0, "Pop-outs only"), (6, "Also sessions you used in the last 6 hours")],
                                   current: code.readyRecentHours, change: { .readyRecentHours($0) },
                                   custom: { "Also sessions you used in the last \(Self.number($0)) hours" })
        case .recap:
            let current: Double = code.awayRecap ? Double(code.recapAfterMinutes) : -1
            var list = [SettingsChoice(title: "Off", change: .awayRecap(afterMinutes: nil), selected: current < 0)]
            for minutes in [15, 30, 60] {
                list.append(SettingsChoice(title: "After \(minutes) min away", change: .awayRecap(afterMinutes: minutes),
                                           selected: current == Double(minutes)))
            }
            if !list.contains(where: \.selected) {
                list.append(SettingsChoice(title: "After \(code.recapAfterMinutes) min away", change: nil, selected: true))
            }
            return list
        case .consoleTheme:
            return [(CodeSettings.Console.Theme.system, "Same as the system"), (.light, "Light"), (.dark, "Dark")].map {
                SettingsChoice(title: $0.1, change: .consoleTheme($0.0), selected: code.console.theme == $0.0)
            }
        default:
            return []
        }
    }

    /// "Main display", each connected display by name, and a selected line for a remembered display that is not
    /// connected (the block uses the main display until it comes back).
    private func displayChoices() -> [SettingsChoice] {
        let remembered = settings.display
        let main = remembered == "main"
        var list = [SettingsChoice(title: "Main display", change: .display("main"), selected: main)]
        var seen: [String: Int] = [:]
        for display in displays() where CodeSettings.isValidDisplay(display.uuid) {
            var title = CodePlainText.line(display.name, limit: 60) ?? "Display"
            let count = (seen[title] ?? 0) + 1
            seen[title] = count
            if count > 1 { title += " (\(count))" }
            let on = !main && display.uuid.caseInsensitiveCompare(remembered) == .orderedSame
            list.append(SettingsChoice(title: title, change: .display(display.uuid), selected: on))
        }
        if !list.contains(where: \.selected) {
            list.append(SettingsChoice(title: "A display that is not connected (main display meanwhile)", change: nil,
                                       selected: true))
        }
        return list
    }

    /// The file-only keys (`CodeSettings.fileOnlyKeys` and `dock.hosts`), in a fixed order, each value in a few words.
    public var fileOnlyRows: [SettingsFileOnlyRow] {
        let code = settings
        func list(_ values: [String], empty: String) -> String { values.isEmpty ? empty : values.joined(separator: ", ") }
        func count(_ n: Int, _ one: String, _ many: String, empty: String) -> String {
            n == 0 ? empty : (n == 1 ? "1 \(one)" : "\(n) \(many)")
        }
        let hidden = code.showText.filter { !$0.value }.keys.sorted()
        let rows: [(String, String)] = [
            ("commands", code.commands == .run ? "run (Run after review)" : "copyOnly (Copy and Type only, no Run)"),
            ("commandShell", code.commandShell == .login ? "login (your login shell)" : "clean (a clean shell)"),
            ("extraPath", list(code.extraPath, empty: "none")),
            ("sandboxDenyFolders", list(code.sandboxDenyFolders, empty: "none")),
            ("sandboxAllowSocketFolders", list(code.sandboxAllowSocketFolders, empty: "none")),
            ("serverNames", count(code.serverNames.count, "server", "servers", empty: "none")),
            ("serverTimeZones", count(code.serverTimeZones.count, "server", "servers", empty: "none (UTC)")),
            ("showText", hidden.isEmpty ? "every copy shows its text" : "text hidden for " + hidden.joined(separator: ", ")),
            ("sayHeadlines", code.sayHeadlines ? "on" : "off"),
            ("profiles", list(code.profiles.map { "\($0.letter) · \($0.name)" }, empty: "none (the default copy only)")),
            ("dashboards", list(code.dashboards.map { $0.host + $0.pathPrefix }, empty: "none (dashboards off)")),
            ("dock.hosts", list(code.dock.hosts, empty: "none")),
        ]
        return rows.map { SettingsFileOnlyRow(key: $0.0, value: CodePlainText.line($0.1, limit: 120) ?? "") }
    }

    // MARK: Helpers

    /// Presets plus, when the file holds another value, a selected line showing it (it has no change).
    private static func withCustom(_ presets: [(Double, String)], current: Double, change: (Double) -> CodeSettings.MenuChange,
                                   custom: (Double) -> String) -> [SettingsChoice] {
        var list = presets.map { SettingsChoice(title: $0.1, change: change($0.0), selected: abs($0.0 - current) < 0.001) }
        if !list.contains(where: \.selected) { list.append(SettingsChoice(title: custom(current), change: nil, selected: true)) }
        return list
    }

    /// 2, 0.5, 1.25: no trailing zeros.
    static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
