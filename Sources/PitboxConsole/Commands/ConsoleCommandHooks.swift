import Foundation

/// What the console needs from the composition root to run command tabs. Plain closures; `ConsoleDrawer` provides
/// them (it installs itself on the console it shows): visible while the block can be shown, reveal by unfolding the
/// block and opening the drawer at its held size, `ready(true)` 0.35 s after the drawer's layout, release by folding
/// the drawer to its bar. The defaults fail closed: the console is never visible, so Run and Type stay off
/// (`ConsoleHost.consoleHiddenReason`).
///
/// Wiring (in the app):
/// ```swift
/// let drawer = ConsoleDrawer(console: console, blockCanShow: { block.canShow }, ensureBlockShown: { done in block.unfold(done) })
/// // console.commandHooks == drawer.commandHooks from here on
/// ```
public struct ConsoleCommandHooks {
    /// Whether the console can show a command now; false when it cannot be shown at all: the block hidden or
    /// folded, or anything else that keeps the drawer off screen. The app never unhides the block by itself
    /// for a command.
    public var consoleVisible: @MainActor () -> Bool

    /// Open the console's drawer at its held size and hold it open while command tabs run (the user sees it run).
    /// Call `ready(true)` once the drawer is laid out at that size, so the command starts at that size, or
    /// `ready(false)` when it cannot be shown (nothing starts then). Without an answer within 2 s nothing starts either.
    public var revealAndHoldConsole: @MainActor (_ ready: @escaping @MainActor (Bool) -> Void) -> Void

    /// End the hold now. The console calls it the console's linger (25 s) after the last Run tab finished, or after a
    /// Type or server tab was set up or a result line revealed a tab; a new Run within those 25 s keeps the hold (one
    /// hold for all Runs, for the latest). Hiding or folding the block, or the user's own fold of the drawer, end it
    /// earlier, by the drawer's rules.
    public var releaseConsoleHold: @MainActor () -> Void

    /// The hooks; each one left out fails closed (never visible, never shown, nothing to release).
    public init(consoleVisible: @escaping @MainActor () -> Bool = { false },
                revealAndHoldConsole: @escaping @MainActor (_ ready: @escaping @MainActor (Bool) -> Void) -> Void = { ready in ready(false) },
                releaseConsoleHold: @escaping @MainActor () -> Void = {}) {
        self.consoleVisible = consoleVisible
        self.revealAndHoldConsole = revealAndHoldConsole
        self.releaseConsoleHold = releaseConsoleHold
    }
}
