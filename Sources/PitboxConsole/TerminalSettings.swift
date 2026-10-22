import Foundation
import PitboxKit

/// What the terminal does when a session's process ends.
enum ExitPolicy: String, CaseIterable {
    /// Keep the tab and show "Process exited ... press Return to restart".
    case keep
    /// Close the tab whatever the exit status.
    case close
    /// Close the tab when the process exited with status 0, keep it (with the hint) otherwise.
    case closeIfClean
}

enum BellMode: String, CaseIterable { case visual, sound, soundAndVisual, none }

/// The console's colors: follow macOS (`system`), or always the dark or the light palette whatever macOS uses.
public enum TerminalAppearance: String, CaseIterable, Sendable { case system, dark, light }

enum CursorShape: String, CaseIterable {
    case blinkBlock, steadyBlock, blinkBar, steadyBar, blinkUnderline, steadyUnderline
}

/// Where the working directory of a new plain shell comes from.
enum NewTabLocation: String, CaseIterable {
    /// The home folder (`$HOME`).
    case home
    /// The folder of the tab that is selected now.
    case current
}

/// How the console's tabs look and behave: a value the app builds from its settings file and hands to `ConsoleHost`
/// (`init(settings:keyboardRequester:)`, `update(settings:)`). The app sets the public fields; everything else keeps the
/// built-in defaults of `standard`.
///
/// `parse(_:)` reads the same keys from a JSON object, tolerantly: every key is optional, unknown keys are ignored, a
/// value of the wrong type or out of range falls back to the default (and is reported as a warning), and one bad preset
/// does not drop the others.
public struct TerminalSettings: Equatable, Sendable {
    /// Absolute path of the login shell to use; nil means `$SHELL`, then the account's shell, then `/bin/zsh`.
    var shell: String?
    /// The terminal font; `SF Mono` (or an unknown or proportional font) means the system monospaced font.
    public var fontName: String
    /// Points, `fontSizeRange` (a value outside it is clamped where the font is made).
    public var fontSize: Double
    var scrollback: Int
    /// Opacity of the terminal's default background, 0.2...1. Text is always opaque; the glass shows through the rest.
    var backgroundOpacity: Double
    var cursorStyle: CursorShape
    var bell: BellMode
    /// Option acts as Meta (sends ESC). Off by default: German and other layouts need Option for @ [ ] { } | ~ \.
    var optionAsMeta: Bool
    var onExit: ExitPolicy
    var newTabLocation: NewTabLocation
    /// Rotate through the tabs automatically (monitoring views). Off by default.
    var autoRotate: Bool
    var autoRotateSeconds: Double
    var maxSessions: Int
    /// Let programs put text on the clipboard with OSC 52. Off by default: a program's output could otherwise plant a
    /// command in the clipboard. Reading the clipboard from a program is never allowed.
    var allowClipboardWrite: Bool
    /// Let a render of the console with `cacheDisplay` or `dataWithPDF` include the terminal's contents. Off by
    /// default: a terminal can show secrets. Command and Type tabs are covered whatever it says.
    var allowSnapshots: Bool
    /// Dark or light console colors regardless of the system appearance; `system` follows macOS.
    public var appearance: TerminalAppearance = .system
    var presets: [TerminalPreset]

    /// The built-in defaults.
    public static let standard = TerminalSettings(
        shell: nil, fontName: "SF Mono", fontSize: 13, scrollback: 10_000, backgroundOpacity: 0.65,
        cursorStyle: .blinkBlock, bell: .visual, optionAsMeta: false, onExit: .closeIfClean, newTabLocation: .home,
        autoRotate: false, autoRotateSeconds: 20, maxSessions: 10, allowClipboardWrite: false, allowSnapshots: false,
        presets: [.builtInShell])

    /// The font sizes the console uses, in points.
    public static let fontSizeRange = 8.0...32.0
    static let scrollbackRange = 100...100_000
    static let opacityRange = 0.2...1.0
    static let rotateSecondsRange = 3.0...3600.0
    static let maxSessionsRange = 1...24

    /// Presets shown in the "+" menu, in file order.
    var enabledPresets: [TerminalPreset] { presets.filter(\.enabled) }

    /// The preset with `id`, if it exists and is enabled.
    func preset(id: String) -> TerminalPreset? { presets.first { $0.id == id && $0.enabled } }

    /// The preset a plain "+" (and the first launch) uses: the one called `shell`, or the built-in.
    var defaultPreset: TerminalPreset { preset(id: "shell") ?? .builtInShell }

    /// Parses a JSON object with the keys above. Returns nil when the data is not a JSON object.
    static func parse(_ data: Data) -> (settings: TerminalSettings, warnings: [String])? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var warnings: [String] = []
        var s = TerminalSettings.standard

        func number(_ key: String) -> Double? {
            guard let raw = root[key] else { return nil }
            if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite { return n.doubleValue }
            warnings.append("\(key): expected a number")
            return nil
        }
        func bool(_ key: String) -> Bool? {
            guard let raw = root[key] else { return nil }
            if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            warnings.append("\(key): expected true or false")
            return nil
        }
        func string(_ key: String) -> String? {
            guard let raw = root[key], !(raw is NSNull) else { return nil }
            if let text = raw as? String { return text }
            warnings.append("\(key): expected a string")
            return nil
        }
        func option<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) -> T? where T.RawValue == String {
            guard let text = string(key) else { return nil }
            if let value = T(rawValue: text) { return value }
            warnings.append("\(key): \"\(text)\" is not one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
            return nil
        }
        func clamped(_ value: Double, _ range: ClosedRange<Double>, _ key: String) -> Double {
            if !range.contains(value) { warnings.append("\(key): \(value) is outside \(range.lowerBound)...\(range.upperBound); clamped") }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        if let path = string("shell") {
            if path.hasPrefix("/"), !path.contains("\0") { s.shell = path }
            else if !path.isEmpty { warnings.append("shell: must be an absolute path like /bin/zsh") }
        }
        if let name = string("fontName"), !name.trimmingCharacters(in: .whitespaces).isEmpty { s.fontName = name }
        if let size = number("fontSize") { s.fontSize = clamped(size, fontSizeRange, "fontSize") }
        if let lines = number("scrollback") {
            let value = clamped(lines, Double(scrollbackRange.lowerBound)...Double(scrollbackRange.upperBound), "scrollback")
            s.scrollback = Int(value)
        }
        if let opacity = number("backgroundOpacity") { s.backgroundOpacity = clamped(opacity, opacityRange, "backgroundOpacity") }
        if let value = option("cursorStyle", CursorShape.self) { s.cursorStyle = value }
        if let value = option("bell", BellMode.self) { s.bell = value }
        if let value = bool("optionAsMeta") { s.optionAsMeta = value }
        if let value = option("onExit", ExitPolicy.self) { s.onExit = value }
        if let value = option("newTabLocation", NewTabLocation.self) { s.newTabLocation = value }
        if let value = bool("autoRotate") { s.autoRotate = value }
        if let seconds = number("autoRotateSeconds") { s.autoRotateSeconds = clamped(seconds, rotateSecondsRange, "autoRotateSeconds") }
        if let count = number("maxSessions") {
            let value = clamped(count, Double(maxSessionsRange.lowerBound)...Double(maxSessionsRange.upperBound), "maxSessions")
            s.maxSessions = Int(value)
        }
        if let value = bool("allowClipboardWrite") { s.allowClipboardWrite = value }
        if let value = bool("allowSnapshots") { s.allowSnapshots = value }
        if let value = option("appearance", TerminalAppearance.self) { s.appearance = value }

        if let rawPresets = root["presets"] {
            if let list = rawPresets as? [Any] {
                var seen = Set<String>()
                var presets: [TerminalPreset] = []
                for (index, raw) in list.enumerated() {
                    guard let preset = TerminalPreset.parse(raw, index: index, warnings: &warnings) else { continue }
                    if !seen.insert(preset.id).inserted {
                        warnings.append("presets[\(index)]: duplicate id \"\(preset.id)\" ignored")
                        continue
                    }
                    presets.append(preset)
                }
                if !presets.contains(where: { $0.id == "shell" }) { presets.insert(.builtInShell, at: 0) }
                s.presets = presets
            } else {
                warnings.append("presets: expected a list")
            }
        }
        return (s, warnings)
    }
}
