import AppKit
import PitboxKit
import PitboxShell

// The app's side of the dock link (`DockWiring`): what the link drives, the panel's first show, and the docked area the
// app's overlays keep out of.
extension PitboxApp {
    /// What a docked host's messages reach besides the panel: the block's focus and the words the spoken line avoids,
    /// the command sandbox's append-only memory, the menu, and the `folded` setting (the one setting the link writes).
    func dockTargets() -> DockWiring.Targets {
        DockWiring.Targets(
            setFocus: { [weak self] name in
                guard let block = self?.block else { return }
                if let name { block.setFocus(named: name) } else { block.setFocus(nil) }
            },
            setHostWakeWords: { [weak self] words in self?.block?.setHostWakeWords(words) },
            rememberPrivateFolders: { [weak self] folders, socketFolders in
                self?.sandboxMemory?.remember(folders: folders, socketFolders: socketFolders)
            },
            stateChanged: { [weak self] in self?.menu?.refresh() },
            persistFolded: { [weak self] folded in
                guard let self, self.settings.folded != folded else { return }
                self.write(.folded(folded))
            })
    }

    /// The panel's first show (the dock link's first placement, docs/DOCK_PROTOCOL.md §8), then everything that
    /// follows the panel.
    func showBlock() {
        guard launched, let panel else { return }
        panel.show()
        syncVisibility()
    }

    /// The regions restored windows and desk tags keep out of: the block's, and docked the host's strip too. Drag-to-pit
    /// keeps the block's own region (a drop arms over the block only).
    var dockedRegions: [ReservedRegion] {
        let own = panel?.regions ?? []
        guard !own.isEmpty, let host = dock.hostRegion else { return own }
        return own + [host]
    }
}
