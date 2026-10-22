import AppKit

// guard-lab: opens throwaway windows of its OWN in and around Pitbox's block and reports what the window guard did to
// them. It never touches any other app's windows: it moves only its own, and reads other apps' windows through the
// window server alone (owner, bounds, layer, on-screen flag; never a title). Needs Pitbox running with Accessibility
// granted and the block shown (unfolded).
//   guard-lab [--bundle-id io.github.drcollect.pitbox] [--region-x 4430] [--edge right|left] [--settle 1.8]
//   guard-lab --adjacent --host-bundle-id <id> [--attended]
//   guard-lab --attended [--steps 10,11,12,13,14,15,20] [--step-timeout 120]
//   guard-lab --zoom-repeat 10
// Exit code 0 when every check passes, 1 otherwise, 2 when the setup is missing. Windows are titled "GUARD-LAB ..." and
// closed again.
// Build: swiftc -O -swift-version 5 tools/guard-lab/main.swift -o tools/bin/guard-lab
//
// Where the reserved area is: by default the block is found through the window server (the tallest on-screen window of
// `--bundle-id` on the main screen) and its edge from the screen edge it touches. `--region-x` gives the window-side x of
// the reserved area instead (with `--edge`, default right). Checks 1-9 need at least 300 pt of it (unfold the block).
//
// --adjacent (design spec §4.4 and §9.3): a host app's strip at the screen edge (`--host-bundle-id`, found the same way)
// and Pitbox docked beside it, each app's guard keeping windows out of its own part. Checks 1-9 then run against the
// whole docked area, and checks 16-19 open windows maximized, straddling both parts, moved into the host's part and
// moved into the block: each must end outside both parts in at most two hops, all toward the window side, with no
// "keeps ending up over the block" line in Pitbox's log (the host's own log is not read). Step 20 (attended, with
// --attended): a person presses the fold hotkey (⌃⌥C) six times within 10 s; the lab watches the block's width, keeps
// one window beside the docked area (it must never move) and moves another into the space each fold frees (each unfold
// must push it out again in one or two hops toward the window side, with no fight line). Run it once on a wide display
// and once on a notebook where the docked area is wider than half the display.
//
// --attended (drag-to-park, check C19): after the automatic checks, steps 10-15 that a person performs with the mouse,
// with Pitbox running, the block shown and "Drag windows into the block to pit them" on. Steps 10, 11 and 14 check the
// guard, 12, 13 and 15 the app's drag-to-park. `--steps` runs only the attended steps listed (no automatic checks). The
// lab still never drags, clicks or moves anything of another app: it watches the button and the pointer
// (CGEventSource, NSEvent.mouseLocation), its own windows' frames and, for Claude's pop-out, only the window server's
// bounds and on-screen flag; it reads Pitbox's settings.json (`dragToPark`) and the new lines of pitbox.log (labels only).

setvbuf(stdout, nil, _IOLBF, 0)

/// Where the reserved area lies: windows belong on the other side.
enum Side: String { case left, right }

var regionXArg: CGFloat?
var edgeArg: Side?
var settle = 1.8
var zoomRepeat = 0   // --zoom-repeat N: run only the zoom scenario N times (hunts intermittent failures)
var attended = false
var attendedOnly: Set<Int>?   // --steps: these attended steps only
var stepTimeout = 120.0
var targetBundleID = "io.github.drcollect.pitbox"
var adjacent = false
var hostBundleID: String?
let attendedSteps: Set<Int> = [10, 11, 12, 13, 14, 15, 20]
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--region-x": regionXArg = args.next().flatMap { Double($0) }.map { CGFloat($0) }
    case "--edge": edgeArg = args.next().flatMap { Side(rawValue: $0) }
    case "--bundle-id": targetBundleID = args.next() ?? targetBundleID
    case "--adjacent": adjacent = true
    case "--host-bundle-id": hostBundleID = args.next()
    case "--zoom-repeat": zoomRepeat = Int(args.next() ?? "") ?? 10
    case "--settle": settle = Double(args.next() ?? "") ?? 1.8
    case "--attended": attended = true
    case "--steps":
        attended = true
        attendedOnly = Set((args.next() ?? "").split(separator: ",").compactMap { Int($0) }
            .filter { attendedSteps.contains($0) })
    case "--step-timeout": stepTimeout = max(10, Double(args.next() ?? "") ?? 120)
    default:
        print("guard-lab: unknown option \(a)")
        exit(2)
    }
}
if adjacent && hostBundleID == nil {
    print("guard-lab: --adjacent needs --host-bundle-id <id>")
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
guard let screen = NSScreen.screens.first else { print("guard-lab: no screen"); exit(2) }
let sf = screen.frame
let vf = screen.visibleFrame
let y0: CGFloat = 300

var failures = 0
func record(_ name: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
}
func fr(_ r: NSRect) -> String { "x \(Int(r.minX))..\(Int(r.maxX))  y \(Int(r.minY))  \(Int(r.width))x\(Int(r.height))" }
func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
func same(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

// MARK: - The window server (owner, bounds, layer, on-screen flag; never a title)

/// One window of the window server. Its name is never read.
struct ServerWindow {
    var number: CGWindowID
    var pid: pid_t
    var bounds: CGRect
    var layer: Int
    var onScreen: Bool
}

func parseServerWindow(_ entry: [String: Any]) -> ServerWindow? {
    guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
          let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
    let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let onScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    return ServerWindow(number: number, pid: pid, bounds: bounds, layer: layer, onScreen: onScreen)
}

func serverWindow(_ number: CGWindowID) -> ServerWindow? {
    let list = (CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]]) ?? []
    return list.compactMap(parseServerWindow).first { $0.number == number }
}

/// On-screen windows, front to back, without the invisible ones.
func onScreenWindows() -> [ServerWindow] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]) ?? []
    return list.filter { (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 }
        .compactMap(parseServerWindow)
}

/// Quartz (origin top-left of the main display, y down) to AppKit (origin bottom-left, y up); x is the same in both.
func appKit(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: sf.maxY - r.maxY, width: r.width, height: r.height) }
func quartz(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: sf.maxY - p.y) }
func qfr(_ r: CGRect) -> String { "x \(Int(r.minX))..\(Int(r.maxX))  y \(Int(r.minY))  \(Int(r.width))x\(Int(r.height))" }

func pids(_ bundleID: String) -> Set<pid_t> {
    Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
}

/// An app's panel (Pitbox's block, a host's strip): its tallest on-screen window on the main screen, at least half the
/// screen high, in AppKit coordinates.
func panel(of bundleID: String) -> NSRect? {
    let owners = pids(bundleID)
    guard !owners.isEmpty else { return nil }
    let main = CGRect(x: sf.minX, y: 0, width: sf.width, height: sf.height)
    return onScreenWindows()
        .filter { owners.contains($0.pid) && $0.bounds.height >= sf.height * 0.5 && $0.bounds.intersects(main) }
        .max { ($0.bounds.height, $0.bounds.width) < ($1.bounds.height, $1.bounds.width) }
        .map { appKit($0.bounds) }
}

/// The screen edge a panel touches (the visible frame's, or the screen's when the Dock is on that side).
func touchedEdge(_ r: NSRect) -> Side? {
    if abs(r.maxX - vf.maxX) <= 2 || abs(r.maxX - sf.maxX) <= 2 { return .right }
    if abs(r.minX - vf.minX) <= 2 || abs(r.minX - sf.minX) <= 2 { return .left }
    return nil
}

// MARK: - Pitbox's files (read only)

/// Pitbox's app-support folder (`PITBOX_APP_SUPPORT` as the app reads it, else ~/Library/Application Support/Pitbox).
var appSupport: URL {
    if let override = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pitbox", isDirectory: true)
}

/// Pitbox's log: ~/Library/Logs/Pitbox/pitbox.log, or `<app support>/logs/pitbox.log` while `PITBOX_APP_SUPPORT` is set.
var logURL: URL {
    if let override = ProcessInfo.processInfo.environment["PITBOX_APP_SUPPORT"], !override.isEmpty {
        return appSupport.appendingPathComponent("logs/pitbox.log")
    }
    return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Pitbox/pitbox.log")
}

/// `dragToPark` in settings.json (true when the key is missing, as the app reads it); nil when unreadable.
func dragToParkSetting() -> Bool? {
    guard let data = try? Data(contentsOf: appSupport.appendingPathComponent("settings.json")),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["dragToPark"] as? Bool ?? true
}

/// The end of pitbox.log now, to read the lines a step adds (labels and numbers only, by the app's logging rules).
func logEnd() -> UInt64? {
    (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.uint64Value
}

/// How many lines added since `mark` contain `text`; nil when the log cannot be read.
func logCount(_ text: String, since mark: UInt64?) -> Int? {
    guard let mark, let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size < mark ? 0 : mark)   // rotated: the new file from its start
    guard let data = try? handle.readToEnd(), let added = String(data: data, encoding: .utf8) else { return 0 }
    return added.split(separator: "\n").filter { $0.contains(text) }.count
}

let claimLine = "[guard] left a window for the strip's drop"
let armedLine = "[code] drop armed"
let parkedLine = "[code] drop parked"
let fightLine = "keeps ending up over the block"

// MARK: - Geometry: the reserved area and its window side

/// `side`: where the reserved area is (`.right`: windows must end at or before `boundary`; `.left`: start at or after
/// it). `block` is Pitbox's part (drag-to-park's drop target); `host` the host's strip with --adjacent.
struct Geometry {
    var side: Side
    var boundary: CGFloat
    var reserved: NSRect
    var block: NSRect
    var host: NSRect?
}

/// Everything from `boundary` to the screen edge on `side`.
func span(_ side: Side, _ boundary: CGFloat) -> NSRect {
    side == .right ? NSRect(x: boundary, y: sf.minY, width: sf.maxX - boundary, height: sf.height)
        : NSRect(x: sf.minX, y: sf.minY, width: boundary - sf.minX, height: sf.height)
}

func findGeometry() -> Geometry {
    let block = panel(of: targetBundleID)
    if adjacent, let hostID = hostBundleID {
        guard let host = panel(of: hostID), let side = touchedEdge(host) else {
            print("guard-lab: the host's strip (\(hostID)) is not shown at an edge of the main screen")
            exit(2)
        }
        guard let block else {
            print("guard-lab: Pitbox's block (\(targetBundleID)) is not shown on the main screen")
            exit(2)
        }
        let beside = side == .right ? abs(block.maxX - host.minX) <= 3 : abs(block.minX - host.maxX) <= 3
        let level = abs(block.minY - host.minY) <= 2 && abs(block.maxY - host.maxY) <= 2
        guard beside && level else {
            print("guard-lab: not docked: block \(fr(block)), host's strip \(fr(host))")
            exit(2)
        }
        let boundary = regionXArg ?? (side == .right ? block.minX : block.maxX)
        return Geometry(side: side, boundary: boundary, reserved: span(side, boundary), block: block, host: host)
    }
    let side = edgeArg ?? block.flatMap(touchedEdge) ?? .right
    if let regionX = regionXArg {
        return Geometry(side: side, boundary: regionX, reserved: span(side, regionX), block: block ?? span(side, regionX))
    }
    guard let block else {
        print("guard-lab: Pitbox's block (\(targetBundleID)) is not shown on the main screen; show it or pass --region-x")
        exit(2)
    }
    let boundary = side == .right ? block.minX : block.maxX
    return Geometry(side: side, boundary: boundary, reserved: span(side, boundary), block: block)
}

let geo = findGeometry()
/// The free width on the window side, and how far the reserved area reaches from the boundary.
let freeWidth = geo.side == .right ? geo.boundary - sf.minX : sf.maxX - geo.boundary
let depth = geo.reserved.width

/// The x of a window `w` wide whose edge facing the reserved area lies `a` points past the boundary (negative: that
/// far on the window side).
func x(_ a: CGFloat, _ w: CGFloat) -> CGFloat { geo.side == .right ? geo.boundary + a : geo.boundary - a - w }
/// The x of a window `w` wide that starts `d` points from the screen edge on the window side.
func xFromScreen(_ d: CGFloat, _ w: CGFloat) -> CGFloat { geo.side == .right ? sf.minX + d : sf.maxX - d - w }
/// Clear of the reserved area (within 1 pt), in AppKit or Quartz coordinates (x is the same in both).
func outside(_ r: CGRect) -> Bool { geo.side == .right ? r.maxX <= geo.boundary + 1 : r.minX >= geo.boundary - 1 }
/// A hop that moved the window toward the window side (or not at all), never back toward the edge.
func towardWindowSide(_ from: NSRect, _ to: NSRect) -> Bool {
    geo.side == .right ? to.maxX <= from.maxX + 1 && to.minX <= from.minX + 1
        : to.minX >= from.minX - 1 && to.maxX >= from.maxX - 1
}

@MainActor
func open(_ title: String, _ frame: NSRect, resizable: Bool = true, minWidth: CGFloat? = nil, panel: Bool = false) -> NSWindow {
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
    if resizable { style.insert(.resizable) }
    let w: NSWindow
    if panel {
        style.insert(.utilityWindow)
        let p = NSPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        w = p
    } else {
        w = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
    }
    w.title = "GUARD-LAB \(title)"
    w.isReleasedWhenClosed = false
    if let m = minWidth { w.minSize = NSSize(width: m, height: 200) }
    w.setFrame(frame, display: true)
    w.orderFrontRegardless()
    return w
}

/// Pretends to be an app that fights the guard: whenever it is narrowed below `threshold` it widens itself again.
final class Fighter: NSObject, NSWindowDelegate {
    var resizes = 0
    let threshold: CGFloat
    let width: CGFloat
    init(threshold: CGFloat, width: CGFloat) {
        self.threshold = threshold
        self.width = width
    }
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        resizes += 1
        if w.frame.width < threshold {
            let width = self.width
            DispatchQueue.main.async {
                var f = w.frame
                f.size.width = width
                w.setFrame(f, display: true)
            }
        }
    }
}

func finish() -> Never {
    print(failures == 0 ? "guard-lab: ALL PASS" : "guard-lab: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

@MainActor
func runLab() async {
    print("guard-lab: screen \(fr(sf)); reserved area \(fr(geo.reserved)) on the \(geo.side.rawValue); every window must "
          + "end on the window side of x=\(Int(geo.boundary)) (\(Int(freeWidth)) pt free)")
    print("guard-lab: block \(fr(geo.block))" + (geo.host.map { "; host's strip \(fr($0))" } ?? ""))

    if let only = attendedOnly {   // --steps: the listed attended steps, without the automatic checks
        await runAttended(only)
        finish()
    }

    if zoomRepeat > 0 {   // hunt for intermittent zoom failures: sample the frame over time as well as at the end
        let width = min(1000, freeWidth * 0.6)
        for i in 1...zoomRepeat {
            let w = open("zoom-\(i)", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 600))
            await sleep(0.5)
            w.zoom(nil)
            var trail: [String] = []
            for _ in 0..<8 { await sleep(0.45); trail.append("\(Int(w.frame.minX))..\(Int(w.frame.maxX))@\(Int(w.frame.minY))") }
            let r = w.frame
            // Did a person touch the mouse during this trial? (The zoomed test window covers most of the screen.)
            let dragged = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged)
            let clicked = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            let human = min(dragged, clicked) < 5.5
            let ok = outside(r) && r.minY >= 0 && r.width > freeWidth * 0.6
            if !ok && human {
                print("SKIP  zoom #\(i): the mouse was used during the trial (drag \(Int(dragged))s ago, click \(Int(clicked))s ago); \(fr(r))")
            } else {
                record("zoom #\(i) ends at the reserved area", ok, "\(fr(r))  trail \(trail.joined(separator: " "))")
            }
            w.close()
            await sleep(0.4)
        }
        finish()
    }

    guard depth >= 300 else {
        record("setup", false, "the reserved area is \(Int(depth)) pt wide (folded?); unfold the block and run again")
        finish()
    }
    await nineChecks()
    if adjacent { await adjacentChecks() }
    if attended { await runAttended(adjacent ? attendedSteps : attendedSteps.subtracting([20])) }
    finish()
}

// MARK: - Checks 1-9 (alone, or against the whole docked area)

@MainActor
func nineChecks() async {
    do { // 1. a window that appears entirely inside the reserved area
        let width = min(700, depth - 60)
        let w = open("inside", NSRect(x: x((depth - width) / 2, width), y: y0, width: width, height: 500))
        await sleep(settle)
        let r = w.frame
        record("window created inside the reserved area is moved out",
               outside(r) && r.minX >= sf.minX && r.maxX <= sf.maxX, fr(r))
        w.close()
    }
    do { // 2. straddling the boundary
        let onSide = min(400, freeWidth - 40), inside = min(500, depth - 20)
        let w = open("straddle", NSRect(x: x(-onSide, onSide + inside), y: y0, width: onSide + inside, height: 500))
        await sleep(settle)
        let r = w.frame
        record("window straddling the boundary is fitted", outside(r) && r.width >= min(300, onSide), fr(r))
        w.close()
    }
    do { // 3. zoom (green button, option-click): expands to the whole visible frame, must settle at the boundary
        let width = min(1000, freeWidth * 0.6)
        let w = open("zoom", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 600))
        await sleep(0.5)
        w.zoom(nil)
        await sleep(settle + 0.8)
        let r = w.frame
        record("zoomed window stops at the boundary", outside(r) && r.width > freeWidth * 0.6, fr(r))
        w.close()
    }
    do { // 4. moved into the reserved area by the app itself after it was created outside
        let width = min(800, freeWidth - 80)
        let w = open("moved-in", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 500))
        await sleep(0.6)
        w.setFrameOrigin(NSPoint(x: x(100, width), y: y0))
        await sleep(settle)
        let r = w.frame
        record("window moved into the reserved area is pushed back", outside(r), fr(r))
        w.close()
    }
    do { // 5. cannot be resized: must be slid, never cut
        let width = min(500, freeWidth - 40)
        let w = open("fixed-size", NSRect(x: x(min(200, max(0, depth - width - 20)), width), y: y0, width: width,
                                          height: 400), resizable: false)
        await sleep(settle)
        let r = w.frame
        record("fixed-size window is slid out (size untouched)", outside(r) && Int(r.width) == Int(width), fr(r))
        w.close()
    }
    do { // 6. wide minimum size: narrowing is impossible, so it must slide
        let minimum = min(1500, freeWidth * 0.6).rounded(.down)
        let onSide = minimum - 100
        let w = open("min-width", NSRect(x: x(-onSide, onSide + 300), y: y0, width: onSide + 300, height: 500),
                     minWidth: minimum)
        await sleep(settle)
        let r = w.frame
        record("window with a wide minimum size is fitted", outside(r) && r.width >= minimum, fr(r))
        w.close()
    }
    do { // 7. floating utility panels are deliberately left alone
        let at = x(min(300, depth - 320), 300)
        let w = open("floating-panel", NSRect(x: at, y: y0, width: 300, height: 300), panel: true)
        await sleep(settle)
        let r = w.frame
        record("floating utility panel is left alone (by design)", Int(r.minX) == Int(at), fr(r))
        w.close()
    }
    do { // 8. burst of moves inside the reserved area
        let width = min(700, freeWidth - 80)
        let w = open("burst", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 500))
        await sleep(0.5)
        for i in 0..<60 {
            w.setFrameOrigin(NSPoint(x: x(CGFloat(50 + (i % 5) * 40), width), y: y0 + CGFloat(i % 3) * 10))
            await sleep(0.015)
        }
        await sleep(settle)
        let r = w.frame
        record("burst of 60 moves ends corrected", outside(r), fr(r))
        w.close()
    }
    do { // 9. an app that fights back: the guard must give up quickly, not loop forever
        let inside = min(600, depth - 20)
        let width = min(1500, freeWidth + inside)
        let fighter = Fighter(threshold: (width * 0.8).rounded(), width: width)
        let w = open("fighter", NSRect(x: x(inside - width, width), y: y0, width: width, height: 500))
        w.delegate = fighter
        await sleep(9)
        let r = w.frame
        let n = fighter.resizes
        record("fighting app does not cause a correction loop", n < 25, "\(n) resize events in 9 s; final \(fr(r))")
        w.delegate = nil
        w.close()
    }
}

// MARK: - Checks 16-19: two guards side by side (--adjacent)

/// One correction as the lab saw it: the window's frame before and after.
typealias Hop = (from: NSRect, to: NSRect)

/// Watches one of the lab's own windows for `seconds`: every new frame that holds for 60 ms is a hop (a correction's
/// size and position writes, a few milliseconds apart, make one hop).
@MainActor
func hops(of w: NSWindow, for seconds: Double) async -> [Hop] {
    var result: [Hop] = []
    var stable = w.frame, candidate = w.frame, since = uptime()
    let end = uptime() + seconds
    while uptime() < end {
        await sleep(0.01)
        let f = w.frame
        if f != candidate {
            candidate = f
            since = uptime()
        } else if candidate != stable && uptime() - since >= 0.06 {
            result.append((stable, candidate))
            stable = candidate
        }
    }
    if candidate != stable { result.append((stable, candidate)) }
    return result
}

/// Outside both parts after at most two hops, all toward the window side, and no fight line in Pitbox's log.
@MainActor
func judge(_ name: String, _ w: NSWindow, _ hops: [Hop], mark: UInt64?) {
    let r = w.frame
    let fights = logCount(fightLine, since: mark)
    let ok = outside(r) && hops.count <= 2 && hops.allSatisfy { towardWindowSide($0.from, $0.to) } && (fights ?? 0) == 0
    let trail = hops.map { "x \(Int($0.to.minX))..\(Int($0.to.maxX))" }.joined(separator: " -> ")
    record(name, ok, "\(hops.count) hop(s)\(trail.isEmpty ? "" : ": " + trail); final \(fr(r)); "
           + "fight lines \(fights.map(String.init) ?? "log unreadable")")
}

@MainActor
func adjacentChecks() async {
    guard let host = geo.host else { return }
    let block = geo.block
    print("guard-lab adjacent: host's strip \(fr(host)), block \(fr(block)); the host's own log is not read")
    /// The x of a window `w` wide that starts `d` points into `part` from its window-side edge (negative: outside).
    func into(_ part: NSRect, by d: CGFloat, _ w: CGFloat) -> CGFloat {
        geo.side == .right ? part.minX + d : part.maxX - d - w
    }

    do { // 16. maximized by the app (no click): the host's guard, then Pitbox's, or Pitbox's alone
        let width = min(800, freeWidth - 80)
        let w = open("adjacent-maximized", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 500))
        await sleep(0.8)
        let mark = logEnd()
        w.setFrame(vf, display: true, animate: false)
        let seen = await hops(of: w, for: 3)
        judge("16 a maximized window ends outside both parts", w, seen, mark: mark)
        w.close()
    }
    do { // 17. created straddling both parts: 200 pt on the window side, the whole block, 200 pt of the host's strip
        let width = block.width + 400
        let mark = logEnd()
        let w = open("adjacent-straddle", NSRect(x: into(block, by: -200, width), y: y0, width: width, height: 500))
        let seen = await hops(of: w, for: 3)
        judge("17 a window straddling both parts ends outside both", w, seen, mark: mark)
        w.close()
    }
    for (number, part, name) in [(18, host, "the host's part"), (19, block, "the block")] {
        let width = min(380, part.width - 60)
        let w = open("adjacent-moved-in", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 500))
        await sleep(0.8)
        let mark = logEnd()
        let start = w.frame.minX, target = into(part, by: 20, width)
        for step in 1...10 {   // the app moves it there in steps, as a drag would (without a mouse button)
            w.setFrameOrigin(NSPoint(x: (start + (target - start) * CGFloat(step) / 10).rounded(), y: y0))
            await sleep(0.02)
        }
        let seen = await hops(of: w, for: 3)
        judge("\(number) a window moved into \(name) ends outside both parts", w, seen, mark: mark)
        w.close()
    }
}

// MARK: - Attended steps 10-15: drag-to-park (check C19); 20: fold and unfold beside a host (--adjacent)
//
// A person drags or presses keys; the lab only watches. 10 and 11 use the lab's own window "GUARD-LAB drag" (never
// claimable); 12-15 a throwaway Claude pop-out, read through the window server alone (bounds, on-screen flag, owner pid;
// never its title).

let claudeBundleID = "com.anthropic.claudefordesktop"
/// A step that should have parked does so within this long; one that should slide back does so within it too (a claim
/// would hold the window for 3 s).
let outcomeWindow = 2.0

func leftButtonDown() -> Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }
/// Drag-to-park's drop target: the block, in AppKit coordinates.
var dropRect: NSRect { geo.block }

func claudePIDs() -> Set<pid_t> { pids(claudeBundleID) }

/// One press of the left button as the lab saw it, polled at 120 Hz.
struct Press {
    /// The window the press went to, and its bounds just before the button went down (the frame before the drag).
    var window: ServerWindow?
    /// How long the pointer was in the block in one stretch: the longest, and the last one up to the release.
    var longestInside = 0.0
    var lastInside = 0.0
    var insideAtRelease = false
    var releasedAt = 0.0
}

/// The frontmost on-screen window under an AppKit point (the one a press there goes to).
func frontWindow(at point: NSPoint) -> ServerWindow? {
    let q = quartz(point)
    return onScreenWindows().first { $0.bounds.contains(q) }
}

/// Waits for the next press and its release. While the button is up it keeps the window under the pointer (and its
/// bounds) so the press's window and frame are the ones from before any move.
@MainActor
func nextPress(timeout: Double) async -> Press? {
    let deadline = uptime() + timeout
    var under: ServerWindow?
    while !leftButtonDown() {
        if uptime() > deadline { return nil }
        under = frontWindow(at: NSEvent.mouseLocation)
        await sleep(1.0 / 60)
    }
    var press = Press(window: under)
    var insideSince: Double?
    let holdLimit = uptime() + 60
    while leftButtonDown(), uptime() < holdLimit {
        let now = uptime()
        if dropRect.contains(NSEvent.mouseLocation) {
            if insideSince == nil { insideSince = now }
            press.longestInside = max(press.longestInside, now - (insideSince ?? now))
        } else {
            insideSince = nil
        }
        await sleep(1.0 / 120)
    }
    press.releasedAt = uptime()
    if let since = insideSince, dropRect.contains(NSEvent.mouseLocation) {
        press.insideAtRelease = true
        press.lastInside = press.releasedAt - since
        press.longestInside = max(press.longestInside, press.lastInside)
    }
    return press
}

/// Polls `condition` every 20 ms for `seconds`; the time it first held, else nil.
@MainActor
func firstTime(within seconds: Double, from start: Double, _ condition: () -> Bool) async -> Double? {
    while uptime() - start < seconds {
        if condition() { return uptime() - start }
        await sleep(0.02)
    }
    return condition() ? uptime() - start : nil
}

/// The throwaway pop-out (12-15) and its frame before step 12's drag.
var popout: (number: CGWindowID, preDrag: CGRect)?

@MainActor
func runAttended(_ steps: Set<Int>) async {
    print("""
    guard-lab attended: steps \(steps.sorted().map(String.init).joined(separator: ", ")).
      Needs Pitbox running with Accessibility and the block shown; for 12-15 "Drag windows into the block to pit them"
      on (the block's ⋯ menu). You drag or press keys; the lab never moves or clicks anything of another app. Each step
      waits up to \(Int(stepTimeout)) s. Steps 12-15 need a throwaway Claude Code session popped out of Claude.
    """)
    guard !pids(targetBundleID).isEmpty else {
        record("attended: Pitbox is running", false, "start it, then run the lab again")
        return
    }
    if !steps.isDisjoint(with: [10, 11]) {
        let width = min(600, freeWidth - 100)
        let w = open("drag", NSRect(x: x(-(width + 60), width), y: y0, width: width, height: 400))
        if steps.contains(10) { await step10(w) }
        if steps.contains(11) { await step11(w) }
        w.close()
    }
    if !steps.isDisjoint(with: [12, 13, 14, 15]) {
        if claudePIDs().isEmpty {
            record("attended: Claude is running", false, "steps 12-15 need a Claude pop-out")
        } else {
            if steps.contains(12) { await step12() }
            if steps.contains(13) { await step13() }
            if steps.contains(14) { await step14() }
            if steps.contains(15) { await step15() }
        }
    }
    if steps.contains(20) { await step20() }
}

/// 10: the lab's own window dragged into the block slides back as before (it can never be claimed).
@MainActor
func step10(_ w: NSWindow) async {
    let name = "10 a non-Claude window dropped in the block slides back"
    for _ in 1...3 {
        print("STEP 10  Drag the window \"GUARD-LAB drag\" by its title bar into the block, hold it there about 1 s, let go.")
        let mark = logEnd()
        guard let press = await nextPress(timeout: stepTimeout) else { return record(name, false, "no drag seen") }
        let released = w.frame
        guard press.insideAtRelease, press.lastInside >= 0.5, !outside(released) else {
            print("RETRY  let go with the pointer and the window in the block, after about 1 s there")
            continue
        }
        let slid = await firstTime(within: outcomeWindow, from: press.releasedAt) { outside(w.frame) }
        let claims = logCount(claimLine, since: mark)
        record(name, slid != nil && (claims ?? 0) == 0,
               "slid back after \(slid.map { String(format: "%.2f s", $0) } ?? "never (2 s)"); \(fr(w.frame)); "
               + "guard claim lines \(claims.map(String.init) ?? "log unreadable")")
        return
    }
    record(name, false, "no valid drag in 3 tries")
}

/// 11: dragged into the block, held 1 s, dragged out and let go: untouched.
@MainActor
func step11(_ w: NSWindow) async {
    let name = "11 dragged in, held, dragged out: untouched"
    for _ in 1...3 {
        print("STEP 11  Drag it into the block, keep it there about 1 s, drag it back out to the window side, let go.")
        guard let press = await nextPress(timeout: stepTimeout) else { return record(name, false, "no drag seen") }
        let released = w.frame
        guard press.longestInside >= 0.8, !press.insideAtRelease, outside(released) else {
            print("RETRY  hold it in the block about 1 s, then let go with the whole window outside the reserved area")
            continue
        }
        await sleep(outcomeWindow)
        record(name, same(w.frame, released, within: 1), "at release \(fr(released)); 2 s later \(fr(w.frame))")
        return
    }
    record(name, false, "no valid drag in 3 tries")
}

/// Waits for the press on the pop-out (the first Claude window pressed when none is known yet).
@MainActor
func popoutPress(_ name: String, instruction: String, valid: (Press) -> String?) async -> Press? {
    for _ in 1...3 {
        print(instruction)
        guard let press = await nextPress(timeout: stepTimeout) else {
            record(name, false, "no drag seen")
            return nil
        }
        guard let window = press.window, claudePIDs().contains(window.pid),
              popout.map({ $0.number == window.number }) ?? true else {
            print("RETRY  that was not \(popout == nil ? "a Claude window" : "the same pop-out"); press its title bar")
            continue
        }
        if let problem = valid(press) {
            print("RETRY  \(problem)")
            continue
        }
        return press
    }
    record(name, false, "no valid drag in 3 tries")
    return nil
}

/// 12: a Claude pop-out dropped in the block goes into the pit (is minimized) within 2 s.
@MainActor
func step12() async {
    let name = "12 a Claude pop-out dropped in the block goes into the pit"
    guard await waitForSetting(true) else { return record(name, false, "drag-to-pit is off") }
    let mark = logEnd()
    guard let press = await popoutPress(name, instruction: "STEP 12  Put the throwaway Claude pop-out beside the reserved "
        + "area, then drag it by its title bar into the block, hold it there about 1 s, let go.", valid: { press in
            press.insideAtRelease && press.lastInside >= 0.5 ? nil : "let go in the block after about 1 s there"
        }), let window = press.window else { return }
    popout = (window.number, window.bounds)
    let off = await firstTime(within: outcomeWindow, from: press.releasedAt) { !(serverWindow(window.number)?.onScreen ?? false) }
    let armed = logCount(armedLine, since: mark), parked = logCount(parkedLine, since: mark)
    let claims = logCount(claimLine, since: mark)
    record(name, off != nil, "off screen \(off.map { String(format: "%.2f s", $0) } ?? "never (2 s)") after the release; "
           + "pre-drag \(qfr(window.bounds)); log: drop armed \(armed.map(String.init) ?? "?"), parked "
           + "\(parked.map(String.init) ?? "?"), guard left it for the drop \(claims.map(String.init) ?? "?")")
}

/// 13: back on track after a click on its monitor, it is at its frame from before the drag (±2 pt).
@MainActor
func step13() async {
    let name = "13 the pop-out back on track is where it was before the drag"
    guard let known = popout else { return record(name, false, "step 12 did not run or did not find the pop-out") }
    print("STEP 13  Click the pop-out's monitor in the block (it reads \"in the pit\").")
    guard await firstTime(within: stepTimeout, from: uptime(), { serverWindow(known.number)?.onScreen ?? false }) != nil,
          var last = serverWindow(known.number)?.bounds else { return record(name, false, "not back on screen") }
    let back = uptime()
    var stableSince = back
    while uptime() - stableSince < 0.5, uptime() - back < 3 {   // settles: the restore's animation ends
        await sleep(0.05)
        guard let now = serverWindow(known.number)?.bounds else { continue }
        if !same(now, last, within: 0.5) { last = now; stableSince = uptime() }
    }
    record(name, same(last, known.preDrag, within: 2), "before the drag \(qfr(known.preDrag)); back \(qfr(last))")
}

/// 14: let go within 0.2 s of entering the block: never armed, so it slides back and stays on screen.
@MainActor
func step14() async {
    let name = "14 a quick drop (under 0.2 s in the block) slides back"
    guard await waitForSetting(true) else { return record(name, false, "drag-to-pit is off") }
    let mark = logEnd()
    guard let press = await popoutPress(name, instruction: "STEP 14  Drag the pop-out into the block and let go at once, "
        + "within 0.2 s of entering it.", valid: { press in
            guard press.insideAtRelease else { return "let go inside the block" }
            return press.lastInside < 0.2 ? nil : String(format: "it was in the block %.2f s: let go sooner", press.lastInside)
        }), let window = press.window else { return }
    if popout == nil { popout = (window.number, window.bounds) }
    await slidBack(name, window.number, press, mark: mark)
}

/// 15: with drag-to-pit off, a drop held 1 s slides back as before.
@MainActor
func step15() async {
    let name = "15 with drag-to-pit off, a drop slides back"
    print("STEP 15  Switch off \"Drag windows into the block to pit them\" in the block's ⋯ menu.")
    guard await waitForSetting(false) else { return record(name, false, "the setting stayed on") }
    let mark = logEnd()
    guard let press = await popoutPress(name, instruction: "STEP 15  Now drag the pop-out into the block, hold it there "
        + "about 1 s, let go.", valid: { press in
            press.insideAtRelease && press.lastInside >= 0.5 ? nil : "let go in the block after about 1 s there"
        }), let window = press.window else { return }
    await slidBack(name, window.number, press, mark: mark)
    print("STEP 15  Switch \"Drag windows into the block to pit them\" back on.")
    if await waitForSetting(true) == false { print("NOTE  the setting is still off") }
}

/// The pop-out ends outside the reserved area within 2 s, never leaves the screen, and nothing armed or claimed it.
@MainActor
func slidBack(_ name: String, _ number: CGWindowID, _ press: Press, mark: UInt64?) async {
    var everOff = false
    let slid = await firstTime(within: outcomeWindow, from: press.releasedAt) {
        guard let window = serverWindow(number) else { everOff = true; return false }
        if !window.onScreen { everOff = true }
        return window.onScreen && outside(window.bounds)
    }
    await sleep(max(0, outcomeWindow - (uptime() - press.releasedAt)))
    if !(serverWindow(number)?.onScreen ?? false) { everOff = true }
    let armed = logCount(armedLine, since: mark), claims = logCount(claimLine, since: mark)
    let quiet = (armed ?? 0) == 0 && (claims ?? 0) == 0
    record(name, slid != nil && !everOff && quiet,
           "in the block \(String(format: "%.2f", press.lastInside)) s; slid back \(slid.map { String(format: "%.2f s", $0) } ?? "never (2 s)"); "
           + "\(everOff ? "went off screen; " : "")log: drop armed \(armed.map(String.init) ?? "?"), guard left it "
           + "\(claims.map(String.init) ?? "?")")
}

/// Waits until settings.json says `dragToPark` is `wanted` (it is written when the menu item is used).
@MainActor
func waitForSetting(_ wanted: Bool) async -> Bool {
    if dragToParkSetting() == wanted { return true }
    print("WAIT   for \"Drag windows into the block to pit them\" to be \(wanted ? "on" : "off") (the block's ⋯ menu)")
    return await firstTime(within: stepTimeout, from: uptime()) { dragToParkSetting() == wanted } != nil
}

/// 20 (--adjacent): fold and unfold three times within 10 s (spec §4.5). A fold frees the space between the block's
/// window-side edge and the rail; half a second after each fold (once the guard has the rail's region) the lab moves its
/// "freed" window there, as an app would. Each unfold must push it out again in one or two hops toward the window side;
/// nothing may move it while folded. The "beside" window, ending at the block's window-side edge, must never move. No
/// fight line in Pitbox's log.
@MainActor
func step20() async {
    let name = "20 fold and unfold three times in 10 s: no fight"
    guard adjacent, geo.host != nil else { return record(name, false, "needs --adjacent") }
    let unfolded = geo.block
    let freedSpace = unfolded.width - 24
    guard freedSpace >= 200 else { return record(name, false, "the block is \(Int(unfolded.width)) pt wide: unfold it") }
    let besideWidth = min(600, freeWidth - 60)
    let beside = open("beside", NSRect(x: x(-besideWidth, besideWidth), y: y0 + 120, width: besideWidth, height: 400))
    let width = min(360, freedSpace - 40)
    let freed = open("freed", NSRect(x: xFromScreen(40, width), y: y0, width: width, height: 400))
    defer {
        beside.close()
        freed.close()
    }
    await sleep(0.8)
    let besideFrame = beside.frame
    let freedX = geo.side == .right ? unfolded.minX + 20 : unfolded.maxX - 20 - width
    for attempt in 1...3 {
        print("STEP 20  Press ⌃⌥C six times within 10 s (fold, unfold, three times), about 1.5 s apart. Do not touch the "
              + "lab's windows.")
        let mark = logEnd()
        var folded = false
        var folds: [Double] = [], unfolds: [Double] = []
        var perUnfold: [[Hop]] = []
        var movedWhileFolded = 0
        var moveAt: Double?
        var stable = freed.frame, candidate = freed.frame, since = uptime()
        var besideMoved = false
        let deadline = uptime() + stepTimeout
        while uptime() < deadline {
            await sleep(0.01)
            let now = uptime()
            if !same(beside.frame, besideFrame, within: 0.5) { besideMoved = true }
            let f = freed.frame
            if f != candidate {
                candidate = f
                since = now
            } else if candidate != stable && now - since >= 0.06 {
                if folded {
                    movedWhileFolded += 1
                } else if !perUnfold.isEmpty {
                    perUnfold[perUnfold.count - 1].append((stable, candidate))
                }
                stable = candidate
            }
            if let at = moveAt, now >= at {
                moveAt = nil
                freed.setFrameOrigin(NSPoint(x: freedX, y: freed.frame.minY))   // the lab's own move, not a hop
                stable = freed.frame
                candidate = stable
                since = now
            }
            if unfolds.count == 3, let last = unfolds.last, now - last >= 1.5 { break }
            guard unfolds.count < 3, let current = panel(of: targetBundleID)?.width else { continue }
            if !folded && current < 60 {
                folded = true
                folds.append(now)
                moveAt = now + 0.5
            } else if folded && current >= unfolded.width - 2 {
                folded = false
                moveAt = nil
                unfolds.append(now)
                perUnfold.append([])
            }
        }
        guard unfolds.count == 3, let firstFold = folds.first else {
            record(name, false, "saw \(folds.count) fold(s) and \(unfolds.count) unfold(s) in \(Int(stepTimeout)) s")
            return
        }
        let took = unfolds[2] - firstFold
        if took > 10 && attempt < 3 {
            print(String(format: "RETRY  three folds and unfolds took %.1f s: press faster", took))
            continue
        }
        let fights = logCount(fightLine, since: mark)
        let counts = perUnfold.map(\.count)
        let directions = perUnfold.allSatisfy { $0.allSatisfy { towardWindowSide($0.from, $0.to) } }
        let ok = took <= 10 && !besideMoved && movedWhileFolded == 0 && outside(freed.frame)
            && counts.allSatisfy { (1...2).contains($0) } && directions && (fights ?? 0) == 0
        record(name, ok, String(format: "%.1f s from the first fold to the third unfold; ", took)
               + "hops per unfold \(counts); moved while folded \(movedWhileFolded); beside window "
               + "\(besideMoved ? "MOVED" : "untouched"); final \(fr(freed.frame)); "
               + "fight lines \(fights.map(String.init) ?? "log unreadable")")
        return
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + (attended ? 1800 : 240)) { print("guard-lab: WATCHDOG timeout"); exit(3) }
Task { @MainActor in await runLab() }
app.run()
