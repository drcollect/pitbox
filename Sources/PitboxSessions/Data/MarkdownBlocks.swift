import Foundation

/// One code block of a reply's markdown, as CommonMark reads it.
struct MarkdownCodeBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A fenced block with its info string (trimmed; empty when there is none).
        case fenced(info: String)
        /// An indented code block (four spaces).
        case indented
    }

    var kind: Kind
    /// The content lines: container prefixes (`> `, list indentation) and the fence's own indentation removed.
    var lines: [String]
    /// Inside a blockquote: a quotation, never offered.
    var inBlockquote: Bool
    /// Up to two lines of text just before the block (its caption, a claim).
    var preceding: [String]
    /// A fenced block ended by its closing fence or by the end of its container (a list item, a blockquote); false when
    /// it was still open at the end of the text (never offered: it may be cut).
    var closed: Bool
}

/// The block structure of CommonMark, as far as code blocks need it: blockquotes, list items (bullets and ordered,
/// nested, with lazy continuation lines), fenced blocks (backticks or tildes, closed by the same character at least as
/// long), indented blocks, paragraphs, headings and thematic breaks. Tabs count to the next multiple of 4 columns where
/// they are indentation; inside code they are kept as they are. HTML blocks and link reference definitions are read as
/// paragraphs (they never hold a fence).
enum MarkdownBlocks {
    /// Every code block of `text`, in order.
    static func codeBlocks(in text: String) -> [MarkdownCodeBlock] {
        var parser = Parser()
        for line in lines(of: text) { parser.take(line) }
        parser.finish()
        return parser.blocks
    }

    /// Lines split at `\n`, `\r\n` and `\r`, as UTF-8 bytes.
    static func lines(of text: String) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8] = []
        var previousCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if previousCR {
                    previousCR = false
                    continue
                }
                result.append(current)
                current = []
            } else if byte == 0x0D {
                result.append(current)
                current = []
                previousCR = true
                continue
            } else {
                current.append(byte)
            }
            previousCR = false
        }
        result.append(current)
        return result
    }

    // MARK: Parser

    private enum Container: Equatable {
        case blockquote
        /// A list item whose content starts `width` columns after its container's content start.
        case listItem(width: Int)
    }

    private struct Fence {
        var character: UInt8
        var length: Int
        var indent: Int
        var info: String
        var lines: [String] = []
        var depth: Int
        var inBlockquote: Bool
        var preceding: [String]
    }

    private struct Indented {
        var lines: [String]
        var blanks: [String] = []
        var depth: Int
        var inBlockquote: Bool
        var preceding: [String]
    }

    private enum Leaf {
        case none, paragraph
        case fenced(Fence)
        case indented(Indented)
    }

    private struct Parser {
        var stack: [Container] = []
        var leaf: Leaf = .none
        /// Text lines since the last code block (the caption is the last two).
        var recentText: [String] = []
        var blocks: [MarkdownCodeBlock] = []

        mutating func take(_ bytes: [UInt8]) {
            var line = LineCursor(bytes)
            var matched = 0
            matching: while matched < stack.count {
                switch stack[matched] {
                case .blockquote:
                    guard line.blockquoteMarkerAhead() else { break matching }
                    line.consumeBlockquoteMarker()
                case .listItem(let width):
                    if line.isBlank {
                        // A blank line keeps list items open.
                    } else if line.indentation() >= width {
                        line.consumeColumns(width)
                    } else {
                        break matching
                    }
                }
                matched += 1
            }

            if case .fenced(var fence) = leaf {
                if matched >= fence.depth {
                    if line.closesFence(character: fence.character, length: fence.length) {
                        finishFence(fence, closed: true)
                        leaf = .none
                    } else {
                        fence.lines.append(line.rest(strippingIndent: fence.indent))
                        leaf = .fenced(fence)
                    }
                    return
                }
                // Its container ended: the block ends with it (CommonMark).
                finishFence(fence, closed: true)
                leaf = .none
            }

            // Where a container did not match, a new block opens outside the paragraph, so the "interrupting a
            // paragraph" limits on list items do not apply (a sibling `2.` item starts a new item).
            if matched < stack.count, case .paragraph = leaf, !line.isBlank, !line.startsBlock(interruptingParagraph: false) {
                // A lazy continuation line of the open paragraph.
                noteText(line.rest())
                return
            }
            if matched < stack.count {
                stack.removeLast(stack.count - matched)
                closeLeaf()
            }

            while true {
                if line.blockquoteMarkerAhead() {
                    closeLeaf()
                    line.consumeBlockquoteMarker()
                    stack.append(.blockquote)
                    continue
                }
                let interrupting: Bool
                if case .paragraph = leaf { interrupting = true } else { interrupting = false }
                if let width = line.consumeListMarker(interruptingParagraph: interrupting) {
                    closeLeaf()
                    stack.append(.listItem(width: width))
                    continue
                }
                break
            }

            if line.isBlank {
                if case .indented(var block) = leaf {
                    block.blanks.append(line.rest(strippingIndent: 4))
                    leaf = .indented(block)
                } else {
                    closeLeaf()
                }
                return
            }
            if let fence = line.fenceOpening() {
                closeLeaf()
                leaf = .fenced(Fence(character: fence.character, length: fence.length, indent: fence.indent,
                                     info: fence.info, depth: stack.count, inBlockquote: stack.contains(.blockquote),
                                     preceding: Array(recentText.suffix(2))))
                return
            }
            if line.indentation() >= 4 {
                switch leaf {
                case .paragraph:
                    noteText(line.rest())
                case .indented(var block):
                    block.lines.append(contentsOf: block.blanks)
                    block.blanks = []
                    block.lines.append(line.rest(strippingIndent: 4))
                    leaf = .indented(block)
                default:
                    closeLeaf()
                    leaf = .indented(Indented(lines: [line.rest(strippingIndent: 4)], depth: stack.count,
                                              inBlockquote: stack.contains(.blockquote),
                                              preceding: Array(recentText.suffix(2))))
                }
                return
            }
            if case .indented = leaf { closeLeaf() }
            if line.isThematicBreak() {
                closeLeaf()
                return
            }
            if line.isATXHeading() {
                closeLeaf()
                noteText(line.rest())
                return
            }
            leaf = .paragraph
            noteText(line.rest())
        }

        mutating func finish() {
            if case .fenced(let fence) = leaf {
                // Still open at the end of the text: recorded as not closed (never offered).
                finishFence(fence, closed: false)
                leaf = .none
            }
            closeLeaf()
        }

        private mutating func closeLeaf() {
            switch leaf {
            case .indented(let block):
                blocks.append(MarkdownCodeBlock(kind: .indented, lines: block.lines, inBlockquote: block.inBlockquote,
                                                preceding: block.preceding, closed: true))
                recentText = []
            case .fenced(let fence):
                finishFence(fence, closed: true)
            case .paragraph, .none:
                break
            }
            leaf = .none
        }

        private mutating func finishFence(_ fence: Fence, closed: Bool) {
            blocks.append(MarkdownCodeBlock(kind: .fenced(info: fence.info), lines: fence.lines,
                                            inBlockquote: fence.inBlockquote, preceding: fence.preceding, closed: closed))
            recentText = []
        }

        private mutating func noteText(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            recentText.append(trimmed)
            if recentText.count > 2 { recentText.removeFirst(recentText.count - 2) }
        }
    }

    // MARK: Line cursor

    /// One line with a position measured in columns (a tab reaches the next multiple of 4). A tab only partly used as
    /// indentation leaves the rest of its columns as spaces before the next byte.
    private struct LineCursor {
        let bytes: [UInt8]
        private(set) var index = 0
        /// The column where the virtual spaces (or, without them, the byte at `index`) start.
        private(set) var column = 0
        private var virtualSpaces = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isBlank: Bool { bytes[index...].allSatisfy { $0 == 0x20 || $0 == 0x09 } }

        /// Columns of whitespace ahead.
        func indentation() -> Int {
            var columns = virtualSpaces
            var col = column + virtualSpaces
            var i = index
            while i < bytes.count {
                if bytes[i] == 0x20 {
                    columns += 1
                    col += 1
                } else if bytes[i] == 0x09 {
                    let width = 4 - col % 4
                    columns += width
                    col += width
                } else {
                    break
                }
                i += 1
            }
            return columns
        }

        /// The first byte after the whitespace ahead, and its index.
        func firstNonSpace() -> (index: Int, byte: UInt8?) {
            var i = index
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            return (i, i < bytes.count ? bytes[i] : nil)
        }

        mutating func consumeColumns(_ count: Int) {
            var left = count
            let fromVirtual = min(left, virtualSpaces)
            virtualSpaces -= fromVirtual
            column += fromVirtual
            left -= fromVirtual
            while left > 0, index < bytes.count {
                let byte = bytes[index]
                if byte == 0x20 {
                    index += 1
                    column += 1
                    left -= 1
                } else if byte == 0x09 {
                    let width = 4 - column % 4
                    index += 1
                    if width <= left {
                        column += width
                        left -= width
                    } else {
                        column += left
                        virtualSpaces = width - left
                        left = 0
                    }
                } else {
                    break
                }
            }
        }

        /// The rest of the line as text (virtual spaces as spaces).
        func rest() -> String {
            String(repeating: " ", count: virtualSpaces) + String(decoding: bytes[index...], as: UTF8.self)
        }

        /// The rest with up to `count` columns of leading whitespace removed.
        func rest(strippingIndent count: Int) -> String {
            var copy = self
            copy.consumeColumns(min(count, copy.indentation()))
            return copy.rest()
        }

        func blockquoteMarkerAhead() -> Bool {
            indentation() <= 3 && firstNonSpace().byte == 0x3E
        }

        /// `>` after up to three columns, and one optional space (or one column of a tab).
        mutating func consumeBlockquoteMarker() {
            consumeColumns(indentation())
            index += 1
            column += 1
            if index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { consumeColumns(1) }
        }

        /// Starts a list item when one starts here: returns its content width and moves past the marker.
        mutating func consumeListMarker(interruptingParagraph: Bool) -> Int? {
            guard indentation() <= 3, !isThematicBreak() else { return nil }
            var probe = self
            let start = probe.column
            probe.consumeColumns(probe.indentation())
            guard probe.index < probe.bytes.count else { return nil }
            let first = probe.bytes[probe.index]
            var ordered = false
            var number = 0
            if first == 0x2D || first == 0x2B || first == 0x2A {
                probe.index += 1
                probe.column += 1
            } else if first >= 0x30, first <= 0x39 {
                var digits = 0
                while probe.index < probe.bytes.count, probe.bytes[probe.index] >= 0x30, probe.bytes[probe.index] <= 0x39, digits < 10 {
                    number = number * 10 + Int(probe.bytes[probe.index] - 0x30)
                    probe.index += 1
                    probe.column += 1
                    digits += 1
                }
                guard digits <= 9, probe.index < probe.bytes.count,
                      probe.bytes[probe.index] == 0x2E || probe.bytes[probe.index] == 0x29 else { return nil }
                probe.index += 1
                probe.column += 1
                ordered = true
            } else {
                return nil
            }
            if probe.index < probe.bytes.count, probe.bytes[probe.index] != 0x20, probe.bytes[probe.index] != 0x09 { return nil }
            let markerEnd = probe.column
            let blankAfter = probe.isBlank
            if interruptingParagraph && (blankAfter || (ordered && number != 1)) { return nil }
            let spaces = probe.indentation()
            let width: Int
            if blankAfter {
                width = markerEnd - start + 1
                probe.consumeColumns(spaces)
            } else if spaces >= 5 {
                width = markerEnd - start + 1
                probe.consumeColumns(1)
            } else {
                width = markerEnd - start + spaces
                probe.consumeColumns(spaces)
            }
            self = probe
            return width
        }

        /// An opening fence: three or more backticks or tildes after up to three columns; a backtick fence's info string
        /// holds no backtick.
        func fenceOpening() -> (character: UInt8, length: Int, indent: Int, info: String)? {
            let indent = indentation()
            guard indent <= 3 else { return nil }
            let (start, byte) = firstNonSpace()
            guard let character = byte, character == 0x60 || character == 0x7E else { return nil }
            var end = start
            while end < bytes.count, bytes[end] == character { end += 1 }
            let length = end - start
            guard length >= 3 else { return nil }
            let infoBytes = bytes[end...]
            if character == 0x60, infoBytes.contains(0x60) { return nil }
            let info = String(decoding: infoBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return (character, length, indent, info)
        }

        /// A closing fence: up to three columns, the fence character at least `length` times, then only whitespace.
        func closesFence(character: UInt8, length: Int) -> Bool {
            guard indentation() <= 3 else { return false }
            let (start, byte) = firstNonSpace()
            guard byte == character else { return false }
            var end = start
            while end < bytes.count, bytes[end] == character { end += 1 }
            guard end - start >= length else { return false }
            return bytes[end...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
        }

        /// Three or more `-`, `*` or `_` (the same one), with only spaces or tabs between them.
        func isThematicBreak() -> Bool {
            guard indentation() <= 3 else { return false }
            let (start, byte) = firstNonSpace()
            guard let mark = byte, mark == 0x2D || mark == 0x2A || mark == 0x5F else { return false }
            var count = 0
            for b in bytes[start...] {
                if b == mark { count += 1 } else if b != 0x20 && b != 0x09 { return false }
            }
            return count >= 3
        }

        /// `#` to `######` followed by a space, a tab or the end of the line.
        func isATXHeading() -> Bool {
            guard indentation() <= 3 else { return false }
            let (start, byte) = firstNonSpace()
            guard byte == 0x23 else { return false }
            var end = start
            while end < bytes.count, bytes[end] == 0x23 { end += 1 }
            guard end - start <= 6 else { return false }
            return end == bytes.count || bytes[end] == 0x20 || bytes[end] == 0x09
        }

        /// Whether a block that may interrupt a paragraph starts here (so the line is not a lazy continuation).
        func startsBlock(interruptingParagraph: Bool) -> Bool {
            if blockquoteMarkerAhead() || fenceOpening() != nil || isThematicBreak() || isATXHeading() { return true }
            var probe = self
            return probe.consumeListMarker(interruptingParagraph: interruptingParagraph) != nil
        }
    }
}
