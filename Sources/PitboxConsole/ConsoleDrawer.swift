import AppKit
import PitboxKit

/// The console's drawer at the bottom of the block: full block width, a 28 pt bar on top and the console's view
/// (`ConsoleHost.makeView()`) under it.
///
/// - **Hidden** (height 0) while the console has no tabs.
/// - **Run** opens it at the held size (`heldHeight`: 4 rows, about 312 pt) and holds it there while a command runs and
///   for the console's linger after the last one ends (25 s, timed by `ConsoleHost`); then it folds to its bar
///   (`barHeight`, 28 pt). A click on the bar opens it; a click on the open drawer's bar folds it, and that fold, the
///   user's own, also ends a hold.
/// - Its height goes to `onHeightChanged`: the block's panel lays the drawer view out at the bottom, full width, that tall
///   (it may animate the change; the console inside keeps its open size and is clipped, never reflowed).
///
/// It is the console's `ConsoleCommandHooks` (installed by `init`; also `commandHooks`):
/// - `consoleVisible` is `blockCanShow()`: the block is shown, or folded and can be unfolded. False while the user or a
///   dock host hid it: then Run, Type and "Open a terminal" are off with the console's reason.
/// - `revealAndHoldConsole` first asks the block to unfold if it is folded (`ensureBlockShown`: Run unfolds the
///   block), then opens and holds the drawer, waits for its layout, and answers `ready(true)` 0.35 s later (the
///   command starts after the drawer's layout), or `ready(false)` when the block could not be shown or the hold ended
///   in between (the user folded the drawer, `blockHidden()`). No answer from the block within 2 s is a `false`.
/// - `releaseConsoleHold` ends the hold (a Run still waiting for its reveal keeps it).
///
/// Nothing here starts, types into or stops a tab: the drawer only shows the console and answers the console's
/// questions. Its bar never takes the keyboard; folding gives the keyboard back if the console had it.
@MainActor
public final class ConsoleDrawer {
    /// What the drawer shows.
    public enum State: Equatable, Sendable {
        /// No tabs (and no Run waiting): height 0.
        case hidden
        /// The bar only (28 pt).
        case folded
        /// The bar and the console (the held size).
        case open
    }

    /// The open drawer's height: 4 rows of the block, about 312 pt, as the console was held open in the app it came from.
    public static let heldHeight: CGFloat = 312
    /// The folded drawer: its bar.
    public static let barHeight: CGFloat = 28
    /// The 0.35 s rule: a command starts this long after the drawer was laid out at the held size.
    static let layoutWait: TimeInterval = 0.35

    /// The drawer's view, for the block's panel to place at its bottom, full width, `height` tall.
    public var view: NSView { drawerView }
    /// What the drawer shows now.
    public private(set) var state: State = .hidden
    /// Whether a Run (or a revealed result, a server tab) holds the drawer open now.
    public private(set) var isHeld = false
    /// Called with the new height whenever it changes: 0 (hidden), `barHeight` (folded) or `heldHeight` (open).
    public var onHeightChanged: ((CGFloat) -> Void)?

    /// The drawer's height for its state.
    public var height: CGFloat {
        switch state {
        case .hidden: return 0
        case .folded: return Self.barHeight
        case .open: return Self.heldHeight
        }
    }

    let console: ConsoleHost
    let drawerView: ConsoleDrawerView
    private let blockCanShow: () -> Bool
    private let ensureBlockShown: (_ done: @escaping (Bool) -> Void) -> Void
    /// The user opened the drawer with a click on its bar (it stays open until folded, the hold ends, or the tabs go).
    private var userOpened = false
    /// Runs waiting for their reveal (each answers once).
    private var reveals: [Reveal] = []

    /// - Parameters:
    ///   - console: the console it shows; the drawer becomes its `commandHooks` and its only tab observer.
    ///   - blockCanShow: whether the block is shown or can be unfolded now; false while the user or a dock host hid it.
    ///   - ensureBlockShown: unfold the block if it is folded, then call `done(true)` once it is shown and laid out, or
    ///     `done(false)` when it cannot be shown. Called on the main thread; answer on the main thread.
    public init(console: ConsoleHost, blockCanShow: @escaping () -> Bool,
                ensureBlockShown: @escaping (_ done: @escaping (Bool) -> Void) -> Void) {
        self.console = console
        self.blockCanShow = blockCanShow
        self.ensureBlockShown = ensureBlockShown
        drawerView = ConsoleDrawerView(content: console.makeView(), contentHeight: Self.heldHeight - Self.barHeight)
        drawerView.bar.onClick = { [weak self] in self?.barClicked() }
        console.onTabsChanged = { [weak self] in self?.tabsChanged() }
        console.commandHooks = commandHooks
        tabsChanged()
    }

    /// The console's command hooks over this drawer (already installed on the console by `init`).
    public var commandHooks: ConsoleCommandHooks {
        ConsoleCommandHooks(
            consoleVisible: { [weak self] in self?.blockCanShow() ?? false },
            revealAndHoldConsole: { [weak self] ready in
                guard let self else { return ready(false) }
                self.revealAndHold(ready)
            },
            releaseConsoleHold: { [weak self] in self?.releaseHold() })
    }

    /// The block was hidden or folded (by the user, the menu or a dock host): the hold ends, a Run still waiting for its
    /// reveal starts nothing, and the drawer folds to its bar (or hides without tabs). Running commands keep running.
    public func blockHidden() {
        for reveal in reveals { answer(reveal, false) }
        isHeld = false
        userOpened = false
        apply()
    }

    // MARK: The hooks

    /// One Run waiting for the drawer: its answer, once.
    private final class Reveal {
        let ready: @MainActor (Bool) -> Void
        var answered = false
        var deadline: ClockToken?
        var layoutTimer: ClockToken?
        init(ready: @escaping @MainActor (Bool) -> Void) { self.ready = ready }
    }

    private func revealAndHold(_ ready: @escaping @MainActor (Bool) -> Void) {
        guard blockCanShow() else { return ready(false) }
        let reveal = Reveal(ready: ready)
        reveals.append(reveal)
        reveal.deadline = console.clock.schedule(after: ConsoleHost.revealTimeout) { [weak self, weak reveal] in
            MainActor.assumeIsolated {
                guard let self, let reveal else { return }
                self.answer(reveal, false)
            }
        }
        var called = false
        ensureBlockShown { [weak self, weak reveal] shown in
            Self.onMainThread {
                guard !called else { return }
                called = true
                guard let self, let reveal, !reveal.answered else { return }
                guard shown, self.blockCanShow() else { return self.answer(reveal, false) }
                self.isHeld = true
                self.apply()
                self.drawerView.layoutSubtreeIfNeeded()
                reveal.layoutTimer = self.console.clock.schedule(after: Self.layoutWait) { [weak self, weak reveal] in
                    MainActor.assumeIsolated {
                        guard let self, let reveal else { return }
                        self.answer(reveal, self.isHeld && self.state == .open && self.blockCanShow())
                    }
                }
            }
        }
    }

    /// Runs `body` on the main actor: at once on the main thread, else on the next turn of the main queue.
    private nonisolated static func onMainThread(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async { MainActor.assumeIsolated(body) } }
    }

    private func answer(_ reveal: Reveal, _ shown: Bool) {
        guard !reveal.answered else { return }
        reveal.answered = true
        reveal.deadline?.cancel()
        reveal.layoutTimer?.cancel()
        reveals.removeAll { $0 === reveal }
        reveal.ready(shown)
    }

    private func releaseHold() {
        // A Run still waiting for its reveal keeps the hold; it ends with that Run's own release.
        guard reveals.isEmpty else { return }
        isHeld = false
        userOpened = false
        apply()
    }

    // MARK: The bar and the tabs

    /// The bar's click: opens a folded drawer; folds an open one (the user's own fold ends a hold, and a Run still
    /// waiting for its reveal starts nothing).
    func barClicked() {
        switch state {
        case .open:
            for reveal in reveals { answer(reveal, false) }
            isHeld = false
            userOpened = false
        case .folded:
            userOpened = true
        case .hidden:
            return
        }
        apply()
    }

    private var tabCount: Int { console.manager?.sessions.count ?? 0 }

    /// A tab came or went or changed: the bar's counts, and without tabs (and no Run waiting) the drawer hides.
    private func tabsChanged() {
        let manager = console.manager
        drawerView.bar.counts = ConsoleDrawerBar.Counts(tabs: manager?.sessions.count ?? 0,
                                                        running: manager?.runningCommandCount ?? 0)
        if let palette = manager?.currentPalette {
            drawerView.bar.palette = palette
            drawerView.bar.tintOpacity = manager?.settings.backgroundOpacity ?? 0.65
        }
        drawerView.bar.appearance = drawerView.content.appearance
        if tabCount == 0, reveals.isEmpty {
            isHeld = false
            userOpened = false
        }
        apply()
    }

    /// Brings the state, the view and the height in line with the hold, the user's choice and the tabs.
    private func apply() {
        let next: State
        if isHeld {
            next = .open
        } else if tabCount == 0 {
            next = .hidden
        } else {
            next = userOpened ? .open : .folded
        }
        guard next != state else { return }
        let wasOpen = state == .open
        state = next
        if wasOpen { releaseKeyboardIfInside() }
        drawerView.show(next)
        onHeightChanged?(height)
    }

    /// Folding or hiding while the console has the keyboard: the console lets go of it (as Cmd-Escape does).
    private func releaseKeyboardIfInside() {
        guard let window = drawerView.window, let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: drawerView.content) else { return }
        window.makeFirstResponder(nil)
        console.keyboardRequester(false)
    }
}
