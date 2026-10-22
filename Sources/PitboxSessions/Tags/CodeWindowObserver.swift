import CoreGraphics
import Foundation

/// Watches Claude's pop-out windows for desk tags and drag-to-park: one
/// `AXObserver` per running Claude copy on a thread of its own with a run loop (the pattern of the guard's
/// `AXObserverSet`, copied: never the main thread, never the guard's or the parker's thread). Notifications: window
/// moved, resized, miniaturized, deminiaturized, destroyed (registered on each watched window), focused and main window
/// changed, application activated, deactivated, hidden and shown. After a notification the watched windows of that copy
/// are read from the window server by number (no Accessibility round trip), at most once per 16 ms per copy.
///
/// It only reads: it never moves, raises, minimizes or otherwise acts on any window. With nothing to watch it observes
/// nothing and runs no timer.
///
/// Several clients share one observer (desk tags, the drag tracker): each states its interest, the observer works for the
/// union, and every client gets every event (each picks what it asked for). Main thread; events arrive on the main
/// thread.
///
/// Wiring (composition root): one `CodeWindowObserver()` handed to `DeskTagController` and to the drag-to-park tracker.
@MainActor
public final class CodeWindowObserver {
    typealias Handler = @MainActor (CodeWindowObserverEvent) -> Void

    let core: CodeWindowObserverCore
    private let queue: DeskTagQueue
    private let toMain: (@escaping @Sendable () -> Void) -> Void
    private var clients: [Int: (handler: Handler, interest: CodeWindowInterest)] = [:]
    private var nextClient = 1
    private var sentInterest = CodeWindowInterest()

    /// The production observer: its own thread, live Accessibility observers, the window server, the button state.
    public convenience init() {
        let thread = DeskTagObserverThread()
        self.init(queue: thread, ax: DeskTagLiveAX(queue: thread), server: DeskTagLiveWindowServer(), button: DeskTagLiveButton(),
                  uptime: { ProcessInfo.processInfo.systemUptime },
                  deliverToMain: { work in DispatchQueue.main.async(execute: work) })
    }

    init(queue: DeskTagQueue, ax: DeskTagAXObserving, server: DeskTagWindowServer, button: DeskTagButton,
         uptime: @escaping () -> TimeInterval, deliverToMain: @escaping (@escaping @Sendable () -> Void) -> Void) {
        self.queue = queue
        toMain = deliverToMain
        let core = CodeWindowObserverCore(queue: queue, ax: ax, server: server, button: button, uptime: uptime)
        self.core = core
        core.deliver = { [weak self, deliverToMain] event in
            deliverToMain { MainActor.assumeIsolated { self?.dispatch(event) } }
        }
    }

    /// A new client; its handler gets every event on the main thread until `removeClient`.
    func addClient(_ handler: @escaping Handler) -> Int {
        let id = nextClient
        nextClient += 1
        clients[id] = (handler, CodeWindowInterest())
        return id
    }

    func removeClient(_ id: Int) {
        clients[id] = nil
        sendInterest()
    }

    /// What client `id` wants now; the observer works for the union of all clients.
    func setInterest(_ interest: CodeWindowInterest, for id: Int) {
        guard clients[id] != nil, clients[id]?.interest != interest else { return }
        clients[id]?.interest = interest
        sendInterest()
    }

    /// Reads every watched window again now (a Space or display change): the answers come as `.windows` events.
    func refreshAll() {
        queue.async { [core] in core.refreshAll() }
    }

    /// The focused window of a Claude copy (the lab's click check), answered on the main thread.
    func focusedWindowNumber(pid: pid_t, _ done: @escaping @MainActor (CGWindowID?) -> Void) {
        let core = self.core
        let toMain = self.toMain
        queue.async {
            let number = core.focusedWindowNumber(pid: pid)
            toMain { MainActor.assumeIsolated { done(number) } }
        }
    }

    /// Stops observing everything (quit). Clients stay registered; a new interest starts it again.
    public func stop() {
        for id in clients.keys { clients[id]?.interest = CodeWindowInterest() }
        sendInterest()
    }

    private func sendInterest() {
        let union = CodeWindowInterest.union(clients.values.map(\.interest))
        guard union != sentInterest else { return }
        sentInterest = union
        queue.async { [core] in core.setInterest(union) }
    }

    private func dispatch(_ event: CodeWindowObserverEvent) {
        for client in clients.values { client.handler(event) }
    }
}
