import AppKit
import PitboxKit

/// The desk peek's window: an opaque 360 pt panel next to the tag, under the
/// tag panel's keyboard rules (`DeskTagNonKeyPanel`: it never becomes key, has no default button and no key equivalent).
/// It closes 0.25 s after the pointer leaves the tag and the panel, when the block hides, and on Escape only through a
/// local key monitor while the app is the active app (the controller holds those rules).
@MainActor
final class DeskPeekPanel {
    let panel: DeskTagNonKeyPanel
    let view: DeskPeekView
    /// The session it shows.
    let sessionID: String

    init(sessionID: String, model: DeskPeekModel) {
        self.sessionID = sessionID
        let frame = CGRect(x: 0, y: 0, width: DeskTagTuning.peekWidth, height: 200)
        view = DeskPeekView(model: model, frame: frame)
        panel = DeskTagNonKeyPanel(contentRect: frame, title: "\(AppIdentity.displayName) session details")
        panel.contentView = view
        // Opaque inside its rounded corners; the shadow follows the shape.
        panel.hasShadow = true
    }

    /// The panel's size for its content: 360 pt wide, as tall as the content up to `maxHeight`.
    func size(maxHeight: CGFloat) -> CGSize {
        CGSize(width: DeskTagTuning.peekWidth, height: min(maxHeight, max(120, view.preferredHeight)))
    }
}
