import AppKit
import PitboxKit

/// "About Pitbox": the standard About panel with the version and the privacy paragraph, said plainly.
public enum AboutPanel {
    /// What the app reads and what it never does (the README says the same).
    public static var privacyParagraph: String {
        let name = AppIdentity.displayName
        return """
        \(name) reads the Claude desktop app's private files on your Mac: the list of Claude Code sessions, the short \
        summaries Claude writes after each turn, the window list, and the ends of session transcripts. Transcripts \
        contain what you typed and what the session did, including file contents and command output, also for sessions \
        running on a server over SSH. To tell Claude's copies apart and match their windows, it also reads the running \
        Claude processes' launch arguments and, with the Accessibility permission, the titles and minimized state of \
        Claude's windows. To keep the block free, the window guard also reads the position, size, kind and minimized \
        and full-screen state of other apps' windows (never their titles or contents) and moves those that cover the \
        block. In some apps (often Electron or Chromium apps) it turns on AXManualAccessibility to see their windows; \
        they may then use more memory, and VS Code may switch to its screen-reader mode. To avoid that, exempt the app \
        with PITBOX_GUARD_EXEMPT or pause the guard from the menu. For sessions on a server it reads your \
        ~/.ssh/config (and, for a file fetch, the system's /etc/ssh/ssh_config) and asks ssh -G to resolve a host \
        name, which never connects. It lists the program names on a fixed PATH to recognise commands; it runs none of \
        them. \(name) reads all this only to show you status and to offer the commands and files a session hands you. \
        Nothing leaves your Mac: no telemetry, no update check, no AI. Links, previews, file fetches and "Open a \
        terminal on <host>" (an SSH connection) happen only when you click. These files are undocumented and can \
        change with any Claude update; \(name) then shows "status unknown" rather than guessing.
        """
    }

    /// The options for `orderFrontStandardAboutPanel(options:)`: name, version and the privacy paragraph as credits.
    @MainActor
    public static func options(version: String) -> [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        let credits = NSAttributedString(string: privacyParagraph, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        return [
            .applicationName: AppIdentity.displayName,
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ]
    }

    /// Shows the About panel in front (an accessory app activates for it).
    @MainActor
    public static func show(version: String = PitboxMenuState.bundleVersion) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options(version: version))
    }
}
