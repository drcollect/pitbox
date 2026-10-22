import CoreGraphics
import PitboxGuard
import PitboxKit
import PitboxSessions
import PitboxShell

/// Between the settings file and the shell (pure): the panel's settings from the file, the file changes for a panel
/// change, and which parts of the app a settings change concerns.
enum SettingsBridge {
    /// The panel's settings as the file says (`columns`, `folded`, `edge`, `display`, `cellWidth`, the gaps and Keep
    /// Above Windows). Hide in full screen is not a setting (always on).
    static func blockSettings(_ s: CodeSettings) -> BlockSettings {
        BlockSettings(columns: s.columns, folded: s.folded, edge: s.edge,
                      displayUUID: BlockDisplay.meansMain(s.display) ? nil : s.display,
                      cellWidth: s.cellWidth, topGap: s.topGap, bottomGap: s.bottomGap, keepAboveWindows: s.keepAboveWindows)
    }

    /// The writes that make the file say `new` where it says `old` (the panel's `onSettingsChanged`): one per key that
    /// differs, in a fixed order.
    static func changes(from old: BlockSettings, to new: BlockSettings) -> [CodeSettings.MenuChange] {
        var out: [CodeSettings.MenuChange] = []
        if new.columns != old.columns { out.append(.columns(new.columns)) }
        if new.folded != old.folded { out.append(.folded(new.folded)) }
        if new.edge != old.edge { out.append(.edge(new.edge)) }
        if new.displayUUID != old.displayUUID { out.append(.display(new.displayUUID ?? BlockDisplay.mainSetting)) }
        if new.cellWidth != old.cellWidth { out.append(.cellWidth(new.cellWidth)) }
        if new.topGap != old.topGap { out.append(.topGap(new.topGap)) }
        if new.bottomGap != old.bottomGap { out.append(.bottomGap(new.bottomGap)) }
        if new.keepAboveWindows != old.keepAboveWindows { out.append(.keepAboveWindows(new.keepAboveWindows)) }
        return out
    }

    /// `settings` without the keys only the shell, the hotkeys, the console, the dock and the login item use, so two
    /// settings that differ only there compare equal: a fold or a column change does not reach the engine and desk tags.
    /// `commands` stays in: the block words its offers and Ready cards by the run policy.
    static func sessionsPart(_ settings: CodeSettings) -> CodeSettings {
        var s = settings
        let defaults = CodeSettings()
        s.columns = defaults.columns
        s.folded = defaults.folded
        s.edge = defaults.edge
        s.display = defaults.display
        s.cellWidth = defaults.cellWidth
        s.topGap = defaults.topGap
        s.bottomGap = defaults.bottomGap
        s.keepAboveWindows = defaults.keepAboveWindows
        s.launchAtLogin = defaults.launchAtLogin
        s.hotkeys = defaults.hotkeys
        s.console = defaults.console
        s.dock = defaults.dock
        s.sandboxDenyFolders = defaults.sandboxDenyFolders
        s.sandboxAllowSocketFolders = defaults.sandboxAllowSocketFolders
        return s
    }

    /// The console's keys of `settings` (font size and theme, the run policy, the shell, the sandbox folders).
    static func consolePart(_ s: CodeSettings) -> [String] {
        [String(s.console.fontSize), s.console.theme.rawValue, s.commands.rawValue, s.commandShell.rawValue]
            + s.extraPath + ["|"] + s.sandboxDenyFolders + ["|"] + s.sandboxAllowSocketFolders
    }
}

/// The block's rows and strip width from the panel (pure).
enum BlockMetrics {
    /// The block's rows for its height (`GridMetrics`: a row is 69 pt, 12 pt between rows): what fits between the
    /// panel's vertical padding, above the drawer and its gutter. At least 1; from 12 rows on the Ready list shows 6 cards.
    static func rows(panelHeight: CGFloat, drawerHeight: CGFloat, verticalPadding: CGFloat) -> Int {
        guard panelHeight.isFinite, panelHeight > 0 else { return 1 }
        let drawer = drawerHeight.isFinite && drawerHeight > 0 ? drawerHeight + GridMetrics.gutter : 0
        let height = panelHeight - 2 * max(0, verticalPadding) - drawer
        let rows = Int(((height + GridMetrics.gutter) / (GridMetrics.rowHeight + GridMetrics.gutter)).rounded(.down))
        return max(1, rows)
    }

    /// The strip width whose `GridMetrics.cellWidth(forStripWidth:)` is the layout's cell (`n·cell + gutters + 2·16`),
    /// so the monitors use exactly the panel's columns. Nil for the rail, and for a cell narrower than
    /// `GridMetrics.minCellWidth` (a docked host's narrow cell): the block view's own width decides then.
    static func stripWidth(for layout: BlockLayout) -> CGFloat? {
        guard !layout.showsRail, layout.columns > 0, layout.cell >= GridMetrics.minCellWidth else { return nil }
        let n = CGFloat(layout.columns)
        return n * layout.cell + (n - 1) * GridMetrics.gutter + 2 * GridMetrics.padding
    }
}

/// Small words and labels the app shows or logs (pure).
enum AppWords {
    /// The log label of a refused ⌃⌥P (never a title).
    static func parkLabel(_ result: CodeParkFrontmostResult) -> String {
        switch result {
        case .parked: return "parked"
        case .alreadyParked: return "already in the pit"
        case .notAPopout: return "not a pop-out"
        case .failed: return "failed"
        case .noAccessibility: return "needs Accessibility"
        }
    }

    /// The guard's status as the menu shows it.
    static func guardMenu(_ status: GuardStatus?) -> (state: GuardMenuState, detail: String?) {
        guard let status else { return (.off, nil) }
        if !status.trusted { return (.needsAccessibility, nil) }
        if status.paused { return (.paused, nil) }
        if status.running {
            let moved = status.correctedCount
            return (.on, moved > 0 ? (moved == 1 ? "1 window moved" : "\(moved) windows moved") : nil)
        }
        return (.off, nil)
    }

    /// Why a hotkey text cannot be used, in the shell parser's words; nil when it parses.
    static func hotkeyProblem(_ spec: String) -> String? {
        switch KeyCombo.parse(spec) {
        case .success: return nil
        case .failure(let error): return "Not a shortcut: \(error)"
        }
    }

    /// How a registered hotkey stands, for the settings window: nil when registered without a warning.
    static func hotkeyStatus(_ registration: HotkeyManager.Registration?) -> String? {
        guard let registration else { return nil }
        switch registration.result {
        case .success(let combo):
            return registration.warning.map { _ in "\(combo) is also a macOS shortcut, which takes precedence" }
        case .failure(let error):
            let keys = (try? KeyCombo.parse(registration.spec).get()).map { "\($0)" } ?? registration.spec
            if registration.isTakenByAnotherApp { return "\(keys) is taken by another app" }
            return "\(keys) unavailable: \(error)"
        }
    }
}
