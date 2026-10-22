import Foundation

/// The rules for bucket names: the user's own words, trimmed, 1-32 characters, with no B1 character, tab or line
/// break. Typing drops those characters as they come; reading `code-buckets.json` refuses a name that typing could not
/// have produced. Two buckets may share a name. Names are never logged.
enum CodeBucketName {
    /// Characters at most, after trimming (`CodeTuning.bucketNameMax`).
    static let maxCharacters = CodeTuning.bucketNameMax
    /// UTF-8 bytes at most: one "character" of a thousand combining marks must not make a huge name to lay out.
    static let maxBytes = 512
    /// The name of a bucket just made, selected for typing over.
    static let newBucket = "New bucket"
    /// Unsorted's fixed name.
    static let unsorted = "Unsorted"

    /// What the field keeps while the user types: B1 characters, tabs and line breaks dropped, then cut to 32 characters
    /// and 512 bytes. Not trimmed (a space between two words is typed before the second word).
    static func typed(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isDropped(scalar) { scalars.append(scalar) }
        var out = ""
        var bytes = 0
        for character in String(scalars) {
            let size = String(character).utf8.count
            guard out.count < maxCharacters, bytes + size <= maxBytes else { break }
            out.append(character)
            bytes += size
        }
        return out
    }

    /// The name Return or a click elsewhere keeps: typed, then trimmed; nil when nothing is left (the old name stays).
    static func committed(_ text: String) -> String? {
        let name = typed(text).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A name read from the file, trimmed; nil when it is empty, longer than 32 characters or 512 bytes, or holds a
    /// character typing would have dropped.
    static func validated(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= maxCharacters, name.utf8.count <= maxBytes,
              !name.unicodeScalars.contains(where: isDropped) else { return nil }
        return name
    }

    /// B1 (the block's plain-text renderer's rule), tabs, and every line break.
    static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar == "\t" || CodePlainText.isHidden(scalar)
    }
}
