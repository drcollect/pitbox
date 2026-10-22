import Darwin
import Foundation

/// What a file Fetch file saved in Downloads gets beside Show in Finder: **Open** for
/// documents (as a double-click in Finder would; the quarantine value stays, macOS checks what it checks), **Preview**
/// for web documents (Pitbox's script-free preview, never the browser), nothing more for archives and
/// anything else. The rule, by the saved name, comes from the composition root (PitboxSessions'
/// `CodeResultFiles.fetchedOpening`); without it a fetched file gets Show in Finder only.
public enum FetchedFileOpening: String, Sendable, Equatable {
    case open, preview, showInFinderOnly

    /// The saved file is still what Open and Preview may act on: a regular file of this user with one link (no link,
    /// folder or FIFO swapped in since the fetch).
    static func isPlainFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && info.st_uid == getuid()
    }
}
