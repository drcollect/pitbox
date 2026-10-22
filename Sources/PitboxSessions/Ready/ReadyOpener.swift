import AppKit
import Foundation

/// Open in Claude: `claude://code/continue?session=local_<id>` in the session's own
/// Claude copy, which opens it in that copy's main window. The id is checked before anything is built; nothing else from
/// a session goes into the link. The app cannot tell which session the main window shows, so it never claims one is
/// on screen there.
enum CodeReadyOpener {
    /// Opens `sessionID` in the running copy `profile` (its process's `Claude.app`); false when the id fails its check
    /// or that copy is not running. `open` receives the link and the app (tests pass a fake).
    @MainActor @discardableResult
    static func openInClaude(_ sessionID: String, profile: CodeProfile, processes: [ClaudeProcessInfo],
                             open: @MainActor (URL, URL) -> Void = CodeReadyOpener.workspaceOpen) -> Bool {
        guard let link = CodeDeepLink.continueURL(sessionID: sessionID),
              let path = processes.first(where: { $0.profile == profile })?.bundlePath, path.hasPrefix("/") else {
            CodeTileLog.info("ready open in claude refused profile=\(profile.letter)")
            return false
        }
        open(link, URL(fileURLWithPath: path, isDirectory: true))
        CodeTileLog.info("ready open in claude profile=\(profile.letter)")
        return true
    }

    /// `NSWorkspace.open(_:withApplicationAt:)`, activating that copy.
    @MainActor static func workspaceOpen(_ link: URL, _ app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration, completionHandler: nil)
    }
}
