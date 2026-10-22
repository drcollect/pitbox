import CoreGraphics
import Foundation
import PitboxKit

/// Where the host wants the docked guest (`place`, docs/DOCK_PROTOCOL.md). Every value is plain data: a frame, numbers,
/// flags and protocol words. The app maps it onto its panel's docked placement.
public struct HostPlace: Equatable, Sendable {
    /// The host's window level, in protocol words.
    public enum Level: String, Sendable, CaseIterable {
        /// Above normal windows (the host's floating − 1).
        case above
        /// Behind normal windows.
        case behind
    }

    /// The host's grid: column width, gap between columns, padding, row height (points).
    public struct Cell: Equatable, Sendable {
        /// The column width (the guest's columns take it).
        public var width: Double
        /// The gap between the host's columns.
        public var gutter: Double
        /// The host's padding at its sides.
        public var padding: Double
        /// The host's row height.
        public var row: Double

        public init(width: Double, gutter: Double = 12, padding: Double = 16, row: Double = 69) {
            self.width = width
            self.gutter = gutter
            self.padding = padding
            self.row = row
        }
    }

    /// Increases with every `place` the host sends; `area` answers it.
    public var seq: Int
    /// The host's display (`CGDirectDisplayID`).
    public var displayID: UInt32
    /// The host's display UUID, when it sent one.
    public var displayUUID: String?
    /// The host's screen edge; the guest sits on the host's window side.
    public var edge: Edge
    /// The host's strip, AppKit global points (origin at the bottom left of the primary display).
    public var host: CGRect
    /// False while the host hides its strip: the guest hides with it.
    public var visible: Bool
    /// The host's level; the guest uses the same.
    public var level: Level
    /// True during the host's live width drag: the guest follows the edge but holds its guard region.
    public var live: Bool
    /// The host's grid.
    public var cell: Cell
    /// The most width the guest may take, points.
    public var maxWidth: Double

    public init(seq: Int, displayID: UInt32, displayUUID: String? = nil, edge: Edge, host: CGRect, visible: Bool = true,
                level: Level = .above, live: Bool = false, cell: Cell, maxWidth: Double = 800) {
        self.seq = seq
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.edge = edge
        self.host = host
        self.visible = visible
        self.level = level
        self.live = live
        self.cell = cell
        self.maxWidth = maxWidth
    }
}

/// The host's look (`appearance`). The raw values are the protocol words.
public struct DockAppearance: Equatable, Sendable {
    /// Light or dark.
    public enum Scheme: String, Sendable, CaseIterable {
        /// Follow the system.
        case system
        case light
        case dark
    }

    /// The material behind the content.
    public enum Backdrop: String, Sendable, CaseIterable {
        /// Liquid Glass.
        case glass
        /// Behind-window vibrancy.
        case vibrancy
        /// An opaque background.
        case solid
    }

    /// Light, dark or the system's.
    public var scheme: Scheme
    /// The material behind the content.
    public var backdrop: Backdrop

    public init(scheme: Scheme = .system, backdrop: Backdrop = .glass) {
        self.scheme = scheme
        self.backdrop = backdrop
    }

    /// The look alone: the system's light or dark, on glass.
    public static let system = DockAppearance()
}

/// The host's focus (`focus.key`): every copy, or a focus by name (the app maps names through its own settings).
public enum DockFocus: Equatable, Sendable {
    /// Every copy shows.
    case all
    /// A focus by the host's name for it (`key`, one line of at most 64 bytes).
    case named(String)

    /// The protocol word.
    public var key: String {
        switch self {
        case .all: return "all"
        case .named(let name): return name
        }
    }
}

/// The host's own private state, announced in its `hello` so the guest's command sandbox keeps commands out of it:
/// folders (files and sockets denied) and socket folders (socket connects denied). Absolute paths, as sent.
public struct HostPrivateFolders: Equatable, Sendable {
    /// Folders whose files and sockets the guest's commands may not touch.
    public var folders: [String]
    /// Folders whose sockets the guest's commands may not connect to.
    public var socketFolders: [String]

    public init(folders: [String] = [], socketFolders: [String] = []) {
        self.folders = folders
        self.socketFolders = socketFolders
    }

    /// True when the host announced nothing.
    public var isEmpty: Bool { folders.isEmpty && socketFolders.isEmpty }
}

/// The `hello` of either side.
struct DockHello: Equatable, Sendable {
    enum Role: String, Sendable { case host, guest }

    var proto: ClosedRange<Int>
    var minor: Int?
    var role: Role
    var app: String
    var build: String
    /// The features the sender listed that this build knows (unknown names are dropped and counted).
    var features: Set<DockFeature>
    /// Host only.
    var wakeWords: [String]
    /// Host only.
    var privateFolders: HostPrivateFolders
}

/// A line from the host to the guest.
enum HostMessage: Equatable, Sendable {
    case hello(DockHello)
    case place(HostPlace)
    case appearance(DockAppearance)
    case focus(DockFocus)
    case speechOK(id: Int)
    case speechNo(id: Int, why: DockSpeechNoReason)
    case fold(Bool)
    case ping
    case pong
    case bye(DockByeReason)

    /// The feature the message needs; nil for the core messages.
    var feature: DockFeature? {
        switch self {
        case .appearance: return .appearance
        case .focus: return .focus
        case .speechOK, .speechNo: return .speech
        case .fold: return .fold
        case .hello, .place, .ping, .pong, .bye: return nil
        }
    }
}

/// A line from the guest to the host.
enum GuestMessage: Equatable, Sendable {
    case hello(DockHello)
    case busy
    case area(seq: Int, frame: CGRect, folded: Bool, visible: Bool)
    case claim(pid: Int32, windowNumber: UInt32)
    case release(pid: Int32, windowNumber: UInt32, parked: Bool)
    case mouseUp
    case attention(needsYou: Int, finished: Int, running: Int)
    case speechBegin(id: Int)
    case speechEnd(id: Int)
    case ping
    case pong
    case bye(DockByeReason)

    /// The feature the message needs; nil for the core messages.
    var feature: DockFeature? {
        switch self {
        case .claim, .release, .mouseUp: return .guardClaims
        case .attention: return .attention
        case .speechBegin, .speechEnd: return .speech
        case .hello, .busy, .area, .ping, .pong, .bye: return nil
        }
    }

    /// Messages of the same kind replace an unsent earlier one when the guest paces its output: only the newest matters.
    var coalesceKey: String? {
        switch self {
        case .area: return "area"
        case .attention: return "attention"
        case .ping: return "ping"
        case .pong: return "pong"
        default: return nil
        }
    }
}
