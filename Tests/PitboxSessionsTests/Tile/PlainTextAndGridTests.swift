import CoreGraphics
import Foundation
import Testing
@testable import PitboxSessions

@Suite("Plain-text renderer")
struct PlainTextTests {
    @Test(arguments: [0x202E, 0x202A, 0x2066, 0x2069, 0x200E, 0x200F, 0x061C, 0x200B, 0x200D, 0xFEFF, 0x00AD, 0x034F,
                      0x115F, 0x1160, 0x17B4, 0x180B, 0x3164, 0xFE0F, 0xFFA0, 0xE0041, 0xE0100, 0x2028, 0x2029, 0x00A0,
                      0x1680, 0x2003, 0x202F, 0x205F, 0x3000, 0x001B, 0x007F, 0x0085, 0x0000, 0x000D] as [UInt32])
    func everyHiddenCharacterOfB1IsShownEscapedInPlace(_ value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(CodePlainText.isHidden(scalar))
        let text = "ok" + String(Character(scalar)) + "go"
        let shown = try #require(CodePlainText.line(text, limit: 200))
        #expect(shown == "ok" + String(format: "⟨U+%04X⟩", value) + "go")
        #expect(!shown.unicodeScalars.contains(scalar))
    }

    @Test func visibleTextIsKeptAsItIs() {
        for text in ["fix the Recipe box import (calm otter)", "Größe · naïve façade", "日本語のテキスト", "emoji 👍🏽 ok", "a-b_c.d"] {
            #expect(CodePlainText.line(text, limit: 200) == text)
        }
        #expect(!CodePlainText.isHidden(" ") && !CodePlainText.isHidden("a"))
    }

    @Test func linesFoldWhitespaceAndBlocksKeepLines() {
        #expect(CodePlainText.line("one\ntwo\tthree   four", limit: 100) == "one two three four")
        #expect(CodePlainText.line("  \n  ", limit: 100) == nil)
        #expect(CodePlainText.line(nil, limit: 100) == nil)
        #expect(CodePlainText.block("first line\r\nsecond line", limit: 100, maxLines: 4) == "first line\nsecond line")
        #expect(CodePlainText.block("1\n2\n3\n4", limit: 100, maxLines: 2) == "1\n2…")
    }

    @Test func textIsCappedAndTheWorkIsBounded() {
        #expect(CodePlainText.line(String(repeating: "x", count: 500), limit: 20)?.count == 20)
        #expect(CodePlainText.line(String(repeating: "x", count: 500), limit: 20)?.hasSuffix("…") == true)
        // A million combining marks are one character; the renderer still stops early.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 1_000_000)
        let shown = CodePlainText.line(zalgo, limit: 10)
        #expect((shown?.unicodeScalars.count ?? 0) < 100)
        // Escapes count toward the limit.
        #expect((CodePlainText.line(String(repeating: "\u{202E}", count: 100), limit: 30)?.count ?? 0) <= 30)
    }

    @Test func commandPreviewsKeepTheirSpaces() {
        #expect(CodePlainText.command("echo ok        ; rm -rf ~/x", limit: 200) == "echo ok        ; rm -rf ~/x")
        #expect(CodePlainText.command("a\tb", limit: 200) == "a→b")
        #expect(CodePlainText.command("sc\u{0441}p x", limit: 200) == "scсp x")   // Cyrillic с is visible text, the sheet flags it
        #expect(CodePlainText.command("ls\u{202E}", limit: 200) == "ls⟨U+202E⟩")
    }
}

@Suite("Folder sizes and pages")
struct GridTests {
    /// The default strip (1024 pt): 3 columns of 322.67 pt; the block 992 pt wide.
    static let column: CGFloat = (1024 - 32 - 24) / 3

    @Test func sizesFollowTheFolderRule() {
        #expect((1...4).allSatisfy { CodeMonitorSize.forCount($0) == .large })
        #expect((5...9).allSatisfy { CodeMonitorSize.forCount($0) == .medium })
        #expect([10, 12, 13, 40].allSatisfy { CodeMonitorSize.forCount($0) == .small })
        #expect(CodeMonitorSize.allCases.map(\.perPage) == [4, 9, 12])
        #expect(CodeMonitorSize.allCases.map(\.height) == [219, 150, 104])
    }

    @Test func monitorsSitOnTheStripsColumns() {
        // At 1024 pt: large and medium one column wide, small half a column, 12 pt gutters.
        let large = CodeMonitorGrid.layout(count: 4, width: 992, stripColumn: Self.column)
        #expect(large.size == .large && large.columns == 3 && large.pages == 1 && large.rows == 2)
        #expect(abs(large.cell.width - 322.67) < 0.1 && large.cell.height == 219)
        #expect(large.bodyHeight == 450 && large.height == 450)
        let medium = CodeMonitorGrid.layout(count: 9, width: 992, stripColumn: Self.column)
        #expect(medium.size == .medium && medium.columns == 3 && medium.rows == 3 && medium.height == 474)
        let small = CodeMonitorGrid.layout(count: 12, width: 992, stripColumn: Self.column)
        #expect(small.size == .small && small.columns == 6 && small.rows == 2 && small.height == 220)
        #expect(abs(small.cell.width - 155.33) < 0.1 && small.cell.height == 104)
        // Fewer monitors need fewer rows.
        #expect(CodeMonitorGrid.layout(count: 2, width: 992, stripColumn: Self.column).height == 219)
        #expect(CodeMonitorGrid.layout(count: 6, width: 992, stripColumn: Self.column).height == 312)
    }

    @Test func otherStripWidthsKeepTheColumns() {
        // Wide (1280 pt): 4 columns of 303 pt; Narrow (768 pt): 2 of 362 pt; the minimum (512 pt): 1 of 480 pt.
        let wide = CodeMonitorGrid.layout(count: 6, width: 1248, stripColumn: 303)
        #expect(wide.columns == 4 && wide.cell.width == 303)
        #expect(CodeMonitorGrid.layout(count: 12, width: 1248, stripColumn: 303).columns == 8)
        #expect(CodeMonitorGrid.layout(count: 3, width: 736, stripColumn: 362).columns == 2)
        let one = CodeMonitorGrid.layout(count: 11, width: 480, stripColumn: 480)
        #expect(one.columns == 2 && abs(one.cell.width - 234) < 0.1)
        // A block narrower than its stated column still fits.
        #expect(CodeMonitorGrid.layout(count: 1, width: 300, stripColumn: 322.67).cell.width == 300)
    }

    @Test func theStripColumnComesFromTheStripOrTheTile() {
        #expect(abs(CodeMonitorGrid.stripColumn(tileWidth: 992, stripWidth: 1024) - 322.67) < 0.01)
        #expect(abs(CodeMonitorGrid.stripColumn(tileWidth: 657.33, stripWidth: 1024) - 322.67) < 0.01)
        #expect(CodeMonitorGrid.stripColumn(tileWidth: 1248, stripWidth: 1280) == 303)
        // A width that does not fit the strip (a test window): the widest columns of at least 300 pt.
        #expect(abs(CodeMonitorGrid.stripColumn(tileWidth: 992, stripWidth: 992) - 322.67) < 0.01)
        #expect(CodeMonitorGrid.stripColumn(tileWidth: 1248, stripWidth: nil) == 303)
        #expect(CodeMonitorGrid.stripColumn(tileWidth: 736, stripWidth: nil) == 362)
    }

    @Test func thirteenSmallMonitorsMakeTwoPagesWithDots() {
        let grid = CodeMonitorGrid.layout(count: 13, width: 992, stripColumn: Self.column)
        #expect(grid.pages == 2)
        #expect(grid.range(ofPage: 0) == 0..<12)
        #expect(grid.range(ofPage: 1) == 12..<13)
        #expect(grid.range(ofPage: 7) == 12..<13)
        #expect(grid.page(of: 12) == 1 && grid.page(of: 0) == 0)
        // Turning the page never changes the folder's height: a full page's rows plus the pager band.
        #expect(grid.height == 220 + 12 + CodeMonitorGrid.pagerHeight)
        #expect(grid.pagerRect(width: 992).minY == 232)
    }

    @Test(arguments: [(CGFloat(992), CGFloat(322.67)), (1248, 303), (736, 362), (480, 480)])
    func slotsNeverOverlapAndStayInside(_ width: CGFloat, _ column: CGFloat) {
        for count in [1, 4, 5, 9, 10, 12, 13, 30] {
            let grid = CodeMonitorGrid.layout(count: count, width: width, stripColumn: column)
            let frames = (0..<min(count, grid.perPage)).map(grid.frame(ofSlot:))
            for (i, a) in frames.enumerated() {
                #expect(a.maxX <= width + 1 && a.maxY <= grid.bodyHeight + CGFloat(grid.rowsPerPage) * 2 + 1,
                        "count \(count) slot \(i) \(a)")
                for b in frames[(i + 1)...] { #expect(!a.insetBy(dx: 1, dy: 1).intersects(b), "count \(count)") }
            }
        }
    }
}
