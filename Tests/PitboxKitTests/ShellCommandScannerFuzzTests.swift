import Foundation
import Testing
@testable import PitboxKit

// Random and pathological input never crashes or hangs the scanner or the classifier, and every range they report stays
// inside the text: pathological input must end fast.

@Suite struct ShellCommandScannerFuzzTests {
    static let alphabet: [Character] = Array("abcrm -f~/.$'\"`\\(){}[]<>|&;#*?!=:,@%^+\n\t0123") + ["\u{00E9}", "\u{200B}", "\u{0441}",
                                                                                                         "\u{1F642}", "\u{2026}"]

    private func checkBounds(_ text: String) {
        let length = text.utf16.count
        let scan = ShellCommandScanner.scan(text)
        if let p = scan.problem { #expect(p.utf16Range.upperBound <= length) }
        for c in scan.comments { #expect(c.upperBound <= length) }
        let a = CC.assess(text, .ssh)
        for f in a.flags {
            #expect(f.utf16Range.lowerBound >= 0 && f.utf16Range.upperBound <= length)
            #expect(f.line >= 1 && f.line <= a.lineCount + 1)
        }
        for s in a.segments { #expect(s.utf16Range.upperBound <= length) }
    }

    @Test func randomTextNeverCrashesAndStaysInBounds() {
        var rng = SeededGenerator(seed: 0xF022)
        let start = Date()
        for _ in 0..<4_000 {
            let n = Int.random(in: 0...120, using: &rng)
            var s = ""
            for _ in 0..<n { s.append(Self.alphabet.randomElement(using: &rng) ?? "a") }
            checkBounds(s)
        }
        #expect(Date().timeIntervalSince(start) < 60)
    }

    @Test func mutatedVectorsNeverCrash() {
        var rng = SeededGenerator(seed: 0xBEEF)
        for vector in ShellVectors.all where vector.text.unicodeScalars.count < 600 {
            var chars = Array(vector.text)
            for _ in 0..<3 {
                guard !chars.isEmpty else { break }
                let k = Int.random(in: 0..<chars.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: chars.remove(at: k)
                case 1: chars.insert(Self.alphabet.randomElement(using: &rng) ?? "a", at: k)
                default: chars[k] = Self.alphabet.randomElement(using: &rng) ?? "a"
                }
            }
            checkBounds(String(chars))
        }
    }

    @Test func pathologicalInputEndsFast() {
        let pieces = ["$(", "${", "\"", "'", "(", "{ ", "[[ ", "((", "`", "<(", "$((", "\\", "<<EOF\n", "if ", "case x in ",
                      "a|", "a;", "a && ", "$'", "!", "{a,", "*(", "#", "\n", "for x in a; do ", "while true; do "]
        for piece in pieces {
            for count in [10, 100, 1_000, 3_000] {
                let text = String(repeating: piece, count: max(1, count / max(1, piece.count)))
                let start = Date()
                checkBounds(text)
                #expect(Date().timeIntervalSince(start) < 1.5, "slow on a repeated piece")
            }
        }
        // Long but readable texts within the limits.
        let readable = [
            String(repeating: "echo a | ", count: 400) + "cat",
            String(repeating: "x=$(echo a); ", count: 280),
            String(repeating: "echo \"$(date)\" ", count: 250),
            "cat <<EOF\n" + String(repeating: "line $(date) `pwd` ${HOME}\n", count: 100) + "EOF",
            String(repeating: "rm -rf build; ", count: 280),
            (0..<40).map { _ in String(repeating: "a", count: 99) }.joined(separator: " | "),
        ]
        for text in readable {
            let start = Date()
            checkBounds(text)
            #expect(Date().timeIntervalSince(start) < 1.5, "slow on a long readable text")
        }
    }
}
