import AppKit
import Foundation
import PitboxKit

/// What an armed press of a result button does, through closures the composition root
/// supplies, so this package opens, reveals and copies nothing by itself:
/// - ↗ a local preview (local sessions only) or an artifact: its address, rebuilt from checked parts, checked once
///   more, in the default browser;
/// - ▤ a document, a web document's Preview, Show in Finder: every file rule again on the resolved path, off the
///   main thread; the file opens only by that path and only when it is still the file seen when the result was made,
///   else "the file changed after you looked";
/// - Copy link (an SSH session's preview) and ⤓ Fetch… (the Fetch file sheet for `<alias>:<path>`, never a raw scp).
/// Log lines carry the session's index and the kind only: `result opened session=#3 kind=preview|artifact|file`.
@MainActor
public final class CodeResultActions {
    /// The closures that act (tests record them).
    public struct Hooks {
        /// A web address in the default browser, or a document in its default app (`NSWorkspace.shared.open`).
        public var openURL: @MainActor (URL) -> Void
        /// `NSWorkspace.shared.activateFileViewerSelecting`: reveals, never opens.
        public var revealInFinder: @MainActor (URL) -> Void
        /// The app's script-free preview of a web document (`CodeWebPreviewController.show`), with its name and the
        /// button's frame in screen coordinates.
        public var preview: @MainActor (URL, String, CGRect) -> Void
        /// An address to the general pasteboard.
        public var copyLink: @MainActor (URL) -> Void
        /// `CommandOfferPresenting.presentFetch(_:source:sessionIndex:anchor:freshness:events:)`.
        public var presentFetch: @MainActor (FetchFileRequest, CommandOffer.Source, Int, CGRect) -> Void

        public init(openURL: @escaping @MainActor (URL) -> Void, revealInFinder: @escaping @MainActor (URL) -> Void,
                    preview: @escaping @MainActor (URL, String, CGRect) -> Void, copyLink: @escaping @MainActor (URL) -> Void,
                    presentFetch: @escaping @MainActor (FetchFileRequest, CommandOffer.Source, Int, CGRect) -> Void) {
            self.openURL = openURL; self.revealInFinder = revealInFinder; self.preview = preview; self.copyLink = copyLink
            self.presentFetch = presentFetch
        }

        /// This Mac: NSWorkspace, the general pasteboard, `preview` and the sheet `presenter` with the click-time
        /// check `freshness` (the `CodeResultFetchChecker` the results deriver feeds) and its `events`.
        public static func live(preview: CodeWebPreviewController, presenter: CommandOfferPresenting,
                                freshness: CommandOfferFreshnessChecking,
                                events: @escaping @MainActor (CommandOfferEvent) -> Void) -> Hooks {
            Hooks(openURL: { NSWorkspace.shared.open($0) },
                  revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                  preview: { [weak preview] url, name, anchor in preview?.show(url, name: name, anchor: anchor) },
                  copyLink: { url in
                      NSPasteboard.general.clearContents()
                      NSPasteboard.general.setString(url.absoluteString, forType: .string)
                  },
                  presentFetch: { [weak presenter] request, source, index, anchor in
                      presenter?.presentFetch(request, source: source, sessionIndex: index, anchor: anchor,
                                              freshness: freshness, events: events)
                  })
        }
    }

    /// How a press ended.
    public enum Outcome: Equatable, Sendable {
        case done
        /// Nothing happened; the app's words ("the file changed after you looked").
        case refused(String)
    }

    private let hooks: Hooks
    private let environment: ResultEnvironment
    private let queue = DispatchQueue(label: "pitbox.code.result-check", qos: .userInitiated)

    /// Actions on this Mac's files (the same rules the results deriver used).
    public convenience init(hooks: Hooks) {
        self.init(hooks: hooks, environment: .live())
    }

    init(hooks: Hooks, environment: ResultEnvironment) {
        self.hooks = hooks
        self.environment = environment
    }

    /// One armed press of `button` on its result in `session` (`anchor`: the button's frame in screen coordinates;
    /// `severalCopies`: more than one Claude copy runs, so the sheet names the copy). `done` runs on the main thread.
    public func perform(_ button: CodeResultButton, session: CodeSessionSnapshot, anchor: CGRect, severalCopies: Bool = false,
                        done: @escaping @MainActor (Outcome) -> Void = { _ in }) {
        guard let result = session.results.first(where: { $0.id == button.resultID }) else {
            done(.refused("the result is gone"))
            return
        }
        switch (button.action, result.kind) {
        case (.open, .preview):
            guard session.place == .local, let url = result.url, case .preview(let checked, _) = ResultLinks.classify(url.absoluteString),
                  checked == url else { return done(.refused("not a local preview")) }
            log(session, "preview")
            hooks.openURL(url)
            done(.done)
        case (.open, .artifact), (.open, .earlierArtifact):
            guard let url = result.url, ResultLinks.artifactURL(url.absoluteString) == url else { return done(.refused("not an artifact")) }
            log(session, "artifact")
            hooks.openURL(url)
            done(.done)
        case (.open, .document), (.preview, .webDocument), (.showInFinder, .document), (.showInFinder, .webDocument),
             (.showInFinder, .otherFile):
            checkFile(result, session: session) { [hooks] outcome in
                switch outcome {
                case .failure(let failure):
                    done(.refused(failure.words))
                case .success(let url):
                    self.log(session, "file")
                    switch button.action {
                    case .open: hooks.openURL(url)
                    case .preview: hooks.preview(url, result.label, anchor)
                    default: hooks.revealInFinder(url)
                    }
                    done(.done)
                }
            }
        case (.copyLink, .serverPreview):
            guard let url = result.url, case .preview(let checked, _) = ResultLinks.classify(url.absoluteString), checked == url else {
                return done(.refused("not a preview"))
            }
            hooks.copyLink(url)
            done(.done)
        case (.fetch, .serverFile):
            guard let made = ResultServerFiles.request(for: result, session: session, severalCopies: severalCopies) else {
                return done(.refused("not a file on the server"))
            }
            hooks.presentFetch(made.request, made.source, session.index, anchor)
            done(.done)
        default:
            done(.refused("not for this result"))
        }
    }

    /// A press on a result shown with a single button (the desk peek rows, `DeskTagActions.openResult`): its first
    /// button, the one the monitor's result line shows (a link's or a document's Open, a web document's Preview, any
    /// other file's Show in Finder).
    public func performPrimary(resultID: String, session: CodeSessionSnapshot, anchor: CGRect, severalCopies: Bool = false,
                               done: @escaping @MainActor (Outcome) -> Void = { _ in }) {
        guard let result = session.results.first(where: { $0.id == resultID }),
              let button = CodeResultWords.buttons(for: result).first else {
            done(.refused("the result is gone"))
            return
        }
        perform(button, session: session, anchor: anchor, severalCopies: severalCopies, done: done)
    }

    // MARK: Fetched files (a Ready result row)

    /// What a press on a fetched file says when it is no longer the file Fetch file saved.
    public static let fetchedChangedWords = "The file changed in Downloads; use Show in Finder."

    /// Open of a file Fetch file saved in Downloads, by its saved name: a document in its default app (the quarantine
    /// value stays; macOS checks what it checks), a web document in the script-free preview, anything else nothing (its
    /// row offers Show in Finder only). Only while `~/Downloads/<name>` is still a regular file of the user's with one
    /// link, so nothing swapped in since the fetch is opened. Checked off the main thread; `done` on the main thread.
    public func openFetched(fileName: String, anchor: CGRect, done: @escaping @MainActor (Outcome) -> Void = { _ in }) {
        let opening = CodeResultFiles.fetchedOpening(fileName: fileName)
        guard opening != .showInFinderOnly else { return done(.refused("not a document")) }
        checkFetched(fileName, plainFile: true) { [hooks] url in
            guard let url else { return done(.refused(Self.fetchedChangedWords)) }
            CodeTileLog.info("fetched file opened kind=\(opening == .open ? "open" : "preview")")
            if opening == .open { hooks.openURL(url) } else { hooks.preview(url, fileName, anchor) }
            done(.done)
        }
    }

    /// Show in Finder of a file Fetch file saved in Downloads: reveals it, never opens it.
    public func showFetchedInFinder(fileName: String, done: @escaping @MainActor (Outcome) -> Void = { _ in }) {
        checkFetched(fileName, plainFile: false) { [hooks] url in
            guard let url else { return done(.refused("the file is no longer in Downloads")) }
            hooks.revealInFinder(url)
            done(.done)
        }
    }

    /// `~/Downloads/<name>` for a saved name (one part under Fetch file's name rules) when it is there: for Open a
    /// regular file of this user with one link, for Show in Finder anything. `completion` on the main thread.
    private func checkFetched(_ name: String, plainFile: Bool, completion: @escaping @MainActor (URL?) -> Void) {
        guard ResultFileTypes.isAcceptableFileName(name) else { return completion(nil) }
        let environment = self.environment
        let path = ResultPaths.lexical(environment.home) + "/Downloads/" + name
        queue.async {
            let found = environment.fileSystem.lstat(path)
            let usable = plainFile ? found.map { $0.kind == .regular && $0.links == 1 && $0.owner == environment.owner } ?? false
                : found != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(usable ? URL(fileURLWithPath: path) : nil) } }
        }
    }

    /// The click-time re-check of a file on this Mac, off the main thread; `completion` on the main thread.
    private func checkFile(_ result: CodeResult, session: CodeSessionSnapshot,
                           completion: @escaping @MainActor (Result<URL, ResultRecheckFailure>) -> Void) {
        guard session.place == .local else { return completion(.failure(.changed)) }
        let check = LocalReportCheck(environment: environment)
        let cwd = session.cwd
        queue.async {
            let outcome = check.recheck(result, cwd: cwd)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
    }

    private func log(_ session: CodeSessionSnapshot, _ kind: String) {
        CodeTileLog.info("result opened session=#\(session.index) kind=\(kind)")
    }
}
