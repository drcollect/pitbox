import Carbon.HIToolbox
import Foundation

/// Which virtual key code types which character on a keyboard layout. Hotkeys register key codes (physical keys),
/// but config strings name characters: on the German layout "z" is the key US keyboards label "Y". Resolving through
/// the current layout makes "ctrl+opt+z" mean the key that types z.
public struct KeyboardLayoutMap: Equatable, Sendable {
    /// Layout name, for logs.
    public var name: String
    /// Lowercased character -> key code (unshifted, main keys only, no keypad).
    public var codes: [String: UInt32]

    public init(name: String, codes: [String: UInt32]) {
        self.name = name
        self.codes = codes
    }

    public func keyCode(for character: String) -> UInt32? { codes[character.lowercased()] }

    /// US ANSI positions. Used when the current layout cannot be read.
    public static let ansi = KeyboardLayoutMap(name: "US (ANSI positions)", codes: {
        let pairs: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket),
            ("]", kVK_ANSI_RightBracket), ("\\", kVK_ANSI_Backslash), (";", kVK_ANSI_Semicolon),
            ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
            ("`", kVK_ANSI_Grave),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, UInt32($0.1)) })
    }())

    /// The current keyboard layout (falls back to the ASCII-capable layout, then to `.ansi`). Main thread only
    /// (Text Input Sources).
    @MainActor
    public static func current() -> KeyboardLayoutMap {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue(), let map = read(source) else { continue }
            return map
        }
        return .ansi
    }

    /// Key codes scanned: the main block (0x00-0x32, which includes the ISO section key 0x0A).
    private static let scannedCodes: [UInt16] = Array(0...0x32)

    private static func read(_ source: TISInputSource) -> KeyboardLayoutMap? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let name: String = {
            guard let p = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "unknown" }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }()
        var codes: [String: UInt32] = [:]
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for code in scannedCodes {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count,
                                            &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let s = String(utf16CodeUnits: chars, count: length).lowercased()
                guard s.count == 1, let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F,
                      !(0xF700...0xF8FF).contains(scalar.value) else { continue }
                if codes[s] == nil { codes[s] = UInt32(code) }
            }
        }
        return codes.isEmpty ? nil : KeyboardLayoutMap(name: name, codes: codes)
    }
}
