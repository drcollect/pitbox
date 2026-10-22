import Foundation

/// The words "Say it" speaks: plain text only, English, never SSML. Headlines are private and are spoken only with
/// `sayHeadlines` (a file-only key); a headline holding a word the spoken line
/// never says (`neverSay` in the settings file, plus the wake words a dock host announces) is never spoken. Pure.
public enum CodeSpokenPhrase {
    /// The generic phrase (the default).
    public static let generic = "A Code session is done"
    /// A headline is cut at a word boundary within this many characters, before " is done".
    static let headlineLimit = 60

    /// The phrase for finishes that coalesced into one alert: "3 Code sessions are done" for several, else the
    /// generic phrase, or "<headline> is done" with `sayHeadlines`.
    public static func finished(headlines: [String], sayHeadlines: Bool, neverSay: [String] = []) -> String {
        if headlines.count > 1 { return "\(headlines.count) Code sessions are done" }
        guard sayHeadlines, let headline = headlines.first else { return generic }
        return headlinePhrase(headline, neverSay: neverSay)
    }

    /// "<headline> is done", or the generic phrase when the headline holds a never-say word, has a hidden or deceptive
    /// character (B1), or has no letters. The check runs on the raw headline, before any cleaning.
    public static func headlinePhrase(_ raw: String, neverSay: [String] = []) -> String {
        guard !holdsNeverSay(raw, words: neverSay), raw.contains(where: \.isLetter),
              !raw.unicodeScalars.contains(where: CodePlainText.isHidden)
        else { return generic }
        let cleaned = speakable(raw)
        guard !cleaned.isEmpty else { return generic }
        return cut(cleaned, limit: headlineLimit) + " is done"
    }

    /// The letters-only check for each word: the text lowercased with every character that is not a letter
    /// removed contains the word (its letters only, lowercased). Also true when the same holds after folding look-alike
    /// letters (accents, full-width forms, other scripts written in Latin letters), which a wake listener hears the same
    /// way. Words without letters never match.
    public static func holdsNeverSay(_ text: String, words: [String]) -> Bool {
        let needles = words.map { fold($0) }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let plain = lettersOnly(text.lowercased())
        let folded = fold(text)
        return needles.contains { plain.contains($0) || folded.contains($0) }
    }

    /// The recap's read-out: counts only, never a headline. Nil when every count is 0.
    public static func recap(finished: Int, waiting: Int, running: Int) -> String? {
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) finished") }
        if waiting > 0 { parts.append(waiting == 1 ? "1 is waiting for you" : "\(waiting) are waiting for you") }
        if running > 0 { parts.append(running == 1 ? "1 is still running" : "\(running) are still running") }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "While you were away, " + list + "."
    }

    // MARK: Pieces

    /// The cleaner of the spoken line: arrows are dropped and runs of whitespace become one space.
    static func speakable(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "→", with: " ")
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` cut at the last space within `limit` characters (or hard at `limit` when the first word is longer).
    static func cut(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let space = head.lastIndex(of: " "), space > head.startIndex {
            return String(head[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return head
    }

    private static func lettersOnly(_ text: String) -> String { String(text.filter(\.isLetter)) }

    /// Look-alike letters folded to plain Latin, lowercased, letters only.
    private static func fold(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let folded = latin.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
        return lettersOnly(folded.lowercased())
    }
}
