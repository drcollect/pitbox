import Foundation
import Testing
@testable import PitboxKit

// Corners of the accepted language (docs/SHELL_LANGUAGE.md §2): zsh's `}` in any position, `case` terminators,
// descriptors, here-docs in substitutions, parameter words, the parts of a word and their ranges, and token counting.

@Suite struct ShellCommandScannerDetailTests {
    private func firstSimple(_ text: String) -> ShellSimpleCommand? {
        guard case .simple(let s)? = ShellCommandScanner.scan(text).script?.items.first?.andOr.pipelines.first?.commands.first
        else { return nil }
        return s
    }

    @Test func closeBraceIsAReservedWordAnywhereButInsideWords() {
        #expect(simpleCommands("{ ls -la }") == [["ls", "-la"]])
        #expect(simpleCommands("echo a}b {}") == [["echo", "a}b", "{}"]])
        #expect(problemKind("ls }") == .syntax)
        #expect(simpleCommands("find . -exec rm {} \\;") == [["find", ".", "-exec", "rm", "{}", ";"]])
        #expect(simpleCommands("echo '}' \"}\" \\}") == [["echo", "}", "}", "}"]])
    }

    @Test func caseTerminatorsAndPatterns() {
        #expect(simpleCommands("case $x in a) echo 1;& b) echo 2;| *) echo 3;; esac") == [["echo", "1"], ["echo", "2"], ["echo", "3"]])
        #expect(simpleCommands("case $x in\n  a|b)\n    echo ab\n    ;;\nesac") == [["echo", "ab"]])
        #expect(simpleCommands("case $x in a) ;; esac").isEmpty)
        #expect(ShellCommandScanner.scan("case $x in (a|(b)) echo;; esac").problem?.rule == .b3)
    }

    @Test func descriptorsAndRedirectionForms() {
        let s = firstSimple("cmd 0<in 1>out 2>>log >&2 2>&- &>>all <<<'x'")
        #expect(s?.redirections.map(\.op) == [.input, .output, .append, .duplicateOutput, .duplicateOutput, .appendOutputAndError, .hereString])
        #expect(s?.redirections.map(\.fileDescriptor) == [0, 1, 2, nil, 2, nil, nil])
        #expect(s?.redirections[3].replacesTarget == false)
        #expect(firstSimple("cmd >& out.txt")?.redirections.first?.replacesTarget == true)
        #expect(problemKind("cmd 12>x") == .notAccepted)
        #expect(problemKind("cmd {fd}>x") == .notAccepted)
        #expect(problemKind("cmd <&x") == .notAccepted)
        #expect(problemKind("x[1]=a") == .notAccepted)
        #expect(ShellCommandScanner.scan("echo a2>x b").isReadable)
        #expect(firstSimple("echo a2>x")?.words.map(\.literalText) == ["echo", "a2"])
    }

    @Test func wordPartsAndTheirRanges() throws {
        let s = try #require(firstSimple("echo ~/x \"$HOME\"/y '$z' $'a\\x41' `pwd` $(ls) ${A:-b} *.md {a,b}"))
        let kinds = s.words.dropFirst().map { w -> String in
            switch w.parts.first {
            case .tilde?: return "tilde"
            case .parameter?: return "parameter"
            case .text(_, let q, _, _)?: return q.rawValue
            case .commandSubstitution(_, let b, _, _)?: return b ? "backticks" : "substitution"
            case .glob?: return "glob"
            case .braceList?: return "brace"
            default: return "other"
            }
        }
        #expect(kinds == ["tilde", "parameter", "single", "ansiC", "backticks", "substitution", "parameter", "glob", "brace"])
        #expect(s.words[3].literalText == "$z")
        #expect(s.words[4].literalText == "aA")
        if case .text(_, _, let decoded, _)? = s.words[4].parts.first { #expect(decoded) }
        if case .parameter(let p)? = s.words[7].parts.first {
            #expect(p.name == "A")
            #expect(p.form == .useDefault)
            #expect(p.word?.literalText == "b")
        }
        if case .braceList(_, let alternatives, _)? = s.words[9].parts.first { #expect(alternatives == ["a", "b"]) }
        // Every range points at the text of its piece.
        let text = "echo \"$(date)\" ${#x} $(( y + 1 ))" as NSString
        let t = try #require(firstSimple(text as String))
        func sub(_ r: Range<Int>) -> String { text.substring(with: NSRange(location: r.lowerBound, length: r.count)) }
        #expect(t.words.map { sub($0.utf16Range) } == ["echo", "\"$(date)\"", "${#x}", "$(( y + 1 ))"])
        if case .commandSubstitution(_, _, let quoted, let r)? = t.words[1].parts.first {
            #expect(quoted)
            #expect(sub(r) == "$(date)")
        }
        if case .arithmetic(let a)? = t.words[3].parts.first {
            #expect(a.expression == " y + 1 ")
            #expect(a.bareNames == ["y"])
        }
    }

    @Test func parameterWordsAndQuoting() {
        #expect(ShellCommandScanner.scan("echo ${A:-a b c}").isReadable)
        #expect(ShellCommandScanner.scan("echo ${A:-'q'}").isReadable)
        #expect(problemKind("echo \"${A:-'q'}\"") == .notAccepted)
        #expect(problemKind("echo ${A:-{x}}") == .notAccepted)
        #expect(simpleCommands("echo ${A:-$(whoami)}") == [["echo", "$…"], ["whoami"]])
        #expect(problemKind("echo ${A:+x}") == .notAccepted)
        #expect(problemKind("echo ${A-x}") == .notAccepted)
        #expect(ShellCommandScanner.scan("echo ${#} ${?} ${10} $10").isReadable)
    }

    @Test func backticksUnescapeOnce() {
        #expect(simpleCommands("echo `echo \\`date\\``") == [["echo", "$…"], ["echo", "$…"], ["date"]])
        #expect(simpleCommands("echo \"`printf \\\"%s\\\" x`\"") == [["echo", "$…"], ["printf", "%s", "x"]])
        #expect(simpleCommands("echo `echo \\$HOME`") == [["echo", "$…"], ["echo", "$…"]])
    }

    @Test func hereDocumentsInsideSubstitutionsAndLoops() {
        #expect(simpleCommands("x=\"$(cat <<'EOF'\nline )\nEOF\n)\"; echo \"$x\"") == [[], ["cat"], ["echo", "$…"]])
        #expect(simpleCommands("while read l; do echo \"$l\"; done <<EOF\na\nb\nEOF") == [["read", "l"], ["echo", "$…"]])
        #expect(problemKind("echo `cat <<EOF`\nbody\nEOF") == .unterminatedHereDocument)
        let scan = ShellCommandScanner.scan("cat <<A <<B\na\nA\nb\nB")
        #expect(scan.hereDocuments.map(\.delimiter) == ["A", "B"])
        #expect(problemKind("cat <<''\nx\n") == .notAccepted)
        #expect(problemKind("cat <<$X\nx\n$X") == .notAccepted)
    }

    @Test func tokensAreCountedIncludingSubstitutions() {
        #expect(ShellCommandScanner.scan("ls -la | wc -l").tokenCount == 5)
        #expect(ShellCommandScanner.scan("echo $(ls)").tokenCount >= 3)
        #expect(ShellCommandScanner.scan(String(repeating: "a;", count: 1_000)).isReadable)     // 2,000: at the limit
        #expect(ShellCommandScanner.scan(String(repeating: "a;", count: 1_001)).problem?.kind == .tooManyTokens)
    }
}
