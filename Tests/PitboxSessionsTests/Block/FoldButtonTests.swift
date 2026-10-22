import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The header's fold "−": in the header's top corner on the block's window side, VoiceOver
/// "Fold Pitbox", calling `PitboxBlock.onFoldRequested`. Off-screen window, never shown.
@MainActor
@Suite("The header's fold button", .serialized)
struct FoldButtonTests {
    init() {
        CodeTileLog.enabled = false
        CodeLog.enabled = false
    }

    /// The block's own root view in an off-screen window that is never ordered in.
    static func blockView(_ block: PitboxBlock) throws -> (CodeMonitorsTileView, NSWindow) {
        let view = try #require(block.makeView() as? CodeMonitorsTileView)
        view.visibilityProbe = { _ in true }
        view.pointerProbe = { nil }
        let size = CGSize(width: 658, height: 600)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 20000, y: 0), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        view.refresh()
        return (view, window)
    }

    @Test func noFoldActionNoButton() throws {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        let (view, _) = try Self.blockView(block)
        #expect(!view.headerButtons().contains { $0.kind == .fold })
        #expect(view.wordsMinX(view.headerButtons()) == 0)
    }

    @Test func theButtonSitsOnTheWindowSideAndFolds() throws {
        let h = TileHarness()
        h.set([tileSession("local_a", "A")])
        let block = PitboxBlock(model: h.model)
        var folds = 0
        block.onFoldRequested = { folds += 1 }
        let (view, _) = try Self.blockView(block)
        // Alone at the right screen edge: the window side is the left, so the "−" takes the left corner.
        var fold = try #require(view.headerButtons().first { $0.kind == .fold })
        #expect(fold.rect.minX == 0 && fold.rect.width == CodeMonitorsTileView.foldWidth && fold.enabled)
        #expect(fold.title == "\u{2212}")
        #expect(view.wordsMinX(view.headerButtons()) == fold.rect.maxX + 8, "the counts start after it")
        #expect(CodeMonitorsTileView.rightButtonsMinX(view.headerButtons()) ?? 0 > fold.rect.maxX,
                "the right-hand buttons stay where they were")
        view.activateHeader(.fold)
        #expect(folds == 1)
        #expect(view.accessibilityLabel(for: .fold) == "Fold Pitbox")
        let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.contains("Fold Pitbox"))
        // At the left screen edge (or docked with the host on the right): the right corner.
        block.foldButtonSide = .right
        view.refresh()
        fold = try #require(view.headerButtons().first { $0.kind == .fold })
        #expect(fold.rect.maxX == view.bounds.width)
        #expect(view.wordsMinX(view.headerButtons()) == 0)
        let others = view.headerButtons().filter { $0.kind != .fold }
        #expect(others.allSatisfy { $0.rect.maxX <= fold.rect.minX - 8 }, "the other buttons move left of it")
        block.onFoldRequested = nil
        view.refresh()
        #expect(!view.headerButtons().contains { $0.kind == .fold })
    }

    @Test func aClickOnTheButtonFolds() throws {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        var folds = 0
        block.onFoldRequested = { folds += 1 }
        let (view, window) = try Self.blockView(block)
        let fold = try #require(view.headerButtons().first { $0.kind == .fold })
        let point = view.convert(CGPoint(x: fold.rect.midX, y: fold.rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        #expect(folds == 1)
    }
}
