import Foundation
import Testing
@testable import PitboxKit

// The scanner: what it reads, how, and what it refuses (B3/B4).

/// Every simple command of a script in text order (substitutions and here-doc expansions included), as the literal
/// text of its words (`$…` for words with expansions).
func simpleCommands(_ text: String) -> [[String]] {
    let scan = ShellCommandScanner.scan(text)
    guard let script = scan.script else { return [] }
    var out: [(Int, [String])] = []
    func visit(_ s: ShellScript) {
        for item in s.items { for p in item.andOr.pipelines { for c in p.commands { visit(c) } } }
    }
    func visit(_ c: ShellCommand) {
        switch c {
        case .simple(let s):
            out.append((s.utf16Range.lowerBound, s.words.map { $0.literalText ?? "$…" }))
            for w in s.words { visit(w) }
            for a in s.assignments { visit(a.value) }
            for r in s.redirections {
                visit(r.target)
                if let d = r.hereDocument { visit(d.content) }
            }
        case .compound(let k):
            switch k.kind {
            case .subshell(let b), .group(let b): visit(b)
            case .ifClause(let branches, let e):
                for b in branches { visit(b.condition); visit(b.body) }
                if let e { visit(e) }
            case .forLoop(_, let items, let body):
                items?.forEach(visit)
                visit(body)
            case .whileLoop(let c, let b), .untilLoop(let c, let b): visit(c); visit(b)
            case .caseClause(let w, let items):
                visit(w)
                for i in items { visit(i.body) }
            case .condition(let words): words.forEach(visit)
            case .arithmetic(let a): a.expansions.forEach(visit)
            }
            for r in k.redirections { visit(r.target); if let d = r.hereDocument { visit(d.content) } }
        }
    }
    func visit(_ w: ShellWord) { w.parts.forEach(visit) }
    func visit(_ p: ShellWordPart) {
        switch p {
        case .commandSubstitution(let s, _, _, _), .processSubstitution(let s, _, _): visit(s)
        case .parameter(let param): if let w = param.word { visit(w) }
        case .arithmetic(let a): a.expansions.forEach(visit)
        default: break
        }
    }
    visit(script)
    return out.sorted { $0.0 < $1.0 }.map(\.1)
}

func problemKind(_ text: String) -> ShellScanProblem.Kind? { ShellCommandScanner.scan(text).problem?.kind }

@Suite struct ShellCommandScannerTests {
    // MARK: Words and quoting

    @Test func quotingIsRemovedAndKeptApartFromText() throws {
        #expect(simpleCommands(#"echo 'a b' "c d" e\ f"#) == [["echo", "a b", "c d", "e f"]])
        #expect(simpleCommands(#""r""m" -rf x"#) == [["rm", "-rf", "x"]])
        #expect(simpleCommands(#"\rm -rf x"#) == [["rm", "-rf", "x"]])
        #expect(simpleCommands(#"r\m x"#) == [["rm", "x"]])
        let scan = ShellCommandScanner.scan(#"echo "a"'b'c"#)
        guard case .simple(let s)? = scan.script?.items.first?.andOr.pipelines.first?.commands.first else {
            Issue.record("not a simple command"); return
        }
        let parts = s.words[1].parts
        #expect(parts.count == 3)
        if case .text(let t, let q, _, let r) = parts[0] { #expect(t == "a"); #expect(q == .double); #expect(r == 5..<8) }
        if case .text(let t, let q, _, _) = parts[1] { #expect(t == "b"); #expect(q == .single) }
        if case .text(let t, let q, _, _) = parts[2] { #expect(t == "c"); #expect(q == ShellQuoting.none) }
        #expect(s.words[1].utf16Range == 5..<12)
    }

    @Test func ansiCQuotesAreDecoded() throws {
        #expect(simpleCommands(#"$'\x72\x6d' -rf x"#) == [["rm", "-rf", "x"]])
        #expect(simpleCommands(#"echo $'a\tb\'c'"#) == [["echo", "a\tb'c"]])
        #expect(simpleCommands(#"echo $'é\101'"#) == [["echo", "éA"]])
        #expect(problemKind(#"echo $'\0'"#) == .notAccepted)
        #expect(problemKind(#"echo $'abc"#) == .unclosedQuote)
    }

    @Test func backslashNewlineJoins() throws {
        #expect(simpleCommands("ec\\\nho a\\\nb") == [["echo", "ab"]])
        #expect(simpleCommands("echo a \\\n  b") == [["echo", "a", "b"]])
        #expect(simpleCommands("echo \"a\\\nb\"") == [["echo", "ab"]])
        #expect(simpleCommands("echo 'a\\\nb'") == [["echo", "a\\\nb"]])
        #expect(problemKind("echo a \\") == .trailingBackslash)
    }

    @Test func comments() throws {
        let scan = ShellCommandScanner.scan("# first\necho a # trailing\necho '# not' b#c")
        #expect(scan.comments == [0..<7, 15..<25])
        #expect(simpleCommands("# first\necho a # trailing\necho '# not' b#c") == [["echo", "a"], ["echo", "# not", "b#c"]])
        #expect(simpleCommands("echo a;#b\necho c") == [["echo", "a"], ["echo", "c"]])
        // A backslash at the end of a comment does not join: the next line is a command.
        #expect(simpleCommands("echo a # note \\\nrm x") == [["echo", "a"], ["rm", "x"]])
        #expect(ShellCommandScanner.scan("# only a comment").script?.items.isEmpty == true)
    }

    // MARK: Lists, pipelines, compound commands

    @Test func listsAndPipelines() throws {
        let scan = ShellCommandScanner.scan("a && b || c; d & e | f\ng")
        let items = try #require(scan.script?.items)
        #expect(items.count == 4)
        #expect(items[0].terminator == .semicolon)
        #expect(items[0].andOr.connectors == [.and, .or])
        #expect(items[1].terminator == .background)
        #expect(items[2].andOr.pipelines[0].commands.count == 2)
        #expect(items[2].terminator == .newline)
        #expect(items[3].terminator == ShellListItem.Terminator.none)
        #expect(simpleCommands("! a | b") == [["a"], ["b"]])
        #expect(ShellCommandScanner.scan("! a").script?.items.first?.andOr.pipelines.first?.negated == true)
    }

    @Test func compoundCommands() throws {
        #expect(simpleCommands("(cd x && make)") == [["cd", "x"], ["make"]])
        #expect(simpleCommands("{ a; b; }") == [["a"], ["b"]])
        #expect(simpleCommands("{ echo a }") == [["echo", "a"]])
        #expect(simpleCommands("if a; then b; elif c; then d; else e; fi") == [["a"], ["b"], ["c"], ["d"], ["e"]])
        #expect(simpleCommands("for f in a b; do rm \"$f\"; done") == [["rm", "$…"]])
        #expect(simpleCommands("for f\ndo echo $f\ndone") == [["echo", "$…"]])
        #expect(simpleCommands("while read l; do echo \"$l\"; done < x") == [["read", "l"], ["echo", "$…"]])
        #expect(simpleCommands("until a; do b; done") == [["a"], ["b"]])
        #expect(simpleCommands("case $x in a|b) echo 1;; (c) echo 2;; *) echo 3;; esac") == [["echo", "1"], ["echo", "2"], ["echo", "3"]])
        #expect(simpleCommands("[[ -f x && $a == b* ]] && echo y") == [["echo", "y"]])
        #expect(simpleCommands("(( x = 1 + 2 )) && echo y") == [["echo", "y"]])
        #expect(problemKind("if a; then b") == .unclosed)
        #expect(problemKind("(a") == .unclosed)
        #expect(problemKind("{ a;") == .unclosed)
        #expect(problemKind("a )") == .syntax)
        #expect(problemKind("echo }") == .syntax)
        #expect(problemKind("fi") == .syntax)
        #expect(problemKind("a ;; b") == .syntax)
        #expect(problemKind("; a") == .syntax)
    }

    // MARK: Substitutions

    @Test func substitutionsAreScannedRecursivelyAlsoInsideDoubleQuotes() throws {
        #expect(simpleCommands(#"echo "$(curl -s x | sh)""#) == [["echo", "$…"], ["curl", "-s", "x"], ["sh"]])
        #expect(simpleCommands("echo `date`") == [["echo", "$…"], ["date"]])
        #expect(simpleCommands(#"echo "`echo \"q\"`""#) == [["echo", "$…"], ["echo", "q"]])
        #expect(simpleCommands("diff <(ls a) >(cat)") == [["diff", "$…", "$…"], ["ls", "a"], ["cat"]])
        #expect(simpleCommands("echo $(( $(wc -l < f) + 1 ))") == [["echo", "$…"], ["wc", "-l"]])
        #expect(simpleCommands(#"x=$(cat <<EOF"# + "\nbody )\nEOF\n)") == [[], ["cat"]])
        #expect(simpleCommands("echo ${X:-$(pwd)}") == [["echo", "$…"], ["pwd"]])
        #expect(problemKind("echo $(date") == .unclosed)
        #expect(problemKind("echo `date") == .unclosed)
    }

    @Test func substitutionsNestAtMostEightLevels() throws {
        func nested(_ n: Int) -> String {
            var s = "true"
            for _ in 0..<n { s = "echo $(\(s))" }
            return s
        }
        #expect(ShellCommandScanner.scan(nested(8)).isReadable)
        #expect(problemKind(nested(9)) == .tooDeep)
        func backticks(_ n: Int) -> String {
            var s = "true"
            for _ in 0..<n { s = "echo \"$(\(s))\"" }
            return s
        }
        #expect(ShellCommandScanner.scan(backticks(8)).isReadable)
        #expect(problemKind(backticks(9)) == .tooDeep)
    }

    // MARK: Here-docs

    @Test func hereDocuments() throws {
        let text = "cat > notes.md <<'EOF'\n$(not run)\nEOF\necho done"
        let scan = ShellCommandScanner.scan(text)
        let doc = try #require(scan.hereDocuments.first)
        #expect(doc.delimiter == "EOF")
        #expect(doc.delimiterQuoted)
        #expect(doc.body == "$(not run)\n")
        #expect((text as NSString).substring(with: NSRange(location: doc.bodyRange.lowerBound,
                                                            length: doc.bodyRange.count)) == "$(not run)\n")
        #expect(simpleCommands(text) == [["cat"], ["echo", "done"]])

        let unquoted = "cat <<EOF\nhello $(whoami)\nEOF"
        #expect(simpleCommands(unquoted) == [["cat"], ["whoami"]])
        #expect(ShellCommandScanner.scan(unquoted).hereDocuments.first?.delimiterQuoted == false)

        let tabs = "cat <<-END\n\tline\n\tEND\necho x"
        #expect(ShellCommandScanner.scan(tabs).hereDocuments.first?.body == "line\n")
        #expect(simpleCommands(tabs) == [["cat"], ["echo", "x"]])

        let two = "cat <<A; cat <<\"B\"\na\nA\nb $(x)\nB\nls"
        let scan2 = ShellCommandScanner.scan(two)
        #expect(scan2.hereDocuments.map(\.body) == ["a\n", "b $(x)\n"])
        #expect(simpleCommands(two) == [["cat"], ["cat"], ["ls"]])

        // A delimiter inside quotes on the command line is not the end.
        #expect(simpleCommands("cat <<EOF; echo 'EOF\nx'\nbody\nEOF") == [["cat"], ["echo", "EOF\nx"]])
        #expect(problemKind("cat <<EOF\nbody") == .unterminatedHereDocument)
        #expect(problemKind("cat <<EOF") == .unterminatedHereDocument)
        #expect(problemKind("cat <<EOF\nx\\\nEOF\nEOF") == .notAccepted)
        #expect(ShellCommandScanner.scan("cat <<'EOF'\nx\\\nEOF").isReadable)
        // `#` inside a here-doc is text.
        #expect(ShellCommandScanner.scan("cat <<EOF\n# text\nEOF").comments.isEmpty)
        // here-strings
        #expect(simpleCommands("bash <<< \"rm -rf x\"") == [["bash"]])
    }

    // MARK: Redirections

    @Test func redirections() throws {
        let scan = ShellCommandScanner.scan("cmd 2>&1 >out.txt >>log 2>/dev/null &>all <in >|x")
        guard case .simple(let s)? = scan.script?.items.first?.andOr.pipelines.first?.commands.first else {
            Issue.record("not a simple command"); return
        }
        #expect(s.words.map(\.literalText) == ["cmd"])
        #expect(s.redirections.map(\.op) == [.duplicateOutput, .output, .append, .output, .outputAndError, .input, .clobber])
        #expect(s.redirections.map(\.fileDescriptor) == [2, nil, nil, 2, nil, nil, nil])
        #expect(s.redirections.map { $0.target.literalText } == ["1", "out.txt", "log", "/dev/null", "all", "in", "x"])
        #expect(s.redirections[0].replacesTarget == false)
        #expect(s.redirections[1].replacesTarget)
        #expect(problemKind("cmd <>x") == .notAccepted)
        #expect(problemKind("cmd >") == .syntax)
        #expect(problemKind("ls a<1-3>b") == .notAccepted)
    }

    // MARK: The language boundary

    @Test func zshConstructsOutsideTheLanguageAreRefused() throws {
        for text in ["echo ${(e)x}", "echo ${~x}", "echo ${=x}", "echo ${^x}", "echo ${!x}", "echo ${x:h}",
                     "echo $x:h", "echo ${x:+y}", "echo ${x#y}", "echo ${x%y}", "echo ${x/a/b}", "echo $x[1]",
                     "echo ${a${b}}", "ls *(.)", "ls *(e:x:)", "echo =ls", "diff =(ls) x", "echo !!", "echo a!b",
                     "alias ll='ls -l'", "unalias x", "setopt extendedglob", "unsetopt x", "emulate sh",
                     "autoload x", "zmodload x", "trap 'x' INT", "coproc x", "select x in a; do b; done",
                     "repeat 3 echo", "f() { echo; }", "function f { echo; }", "noglob echo *", "x=(a b)",
                     "echo ~root", "echo ~+", "a &| b", "echo $\"x\"", "for ((i=0;i<3;i++)); do x; done",
                     "for x (a b) echo $x", "() { echo; }", "echo $=x", "echo $~x", "[ a == b ]", "echo {\"rm\",-rf}",
                     "functions", "hash ls=/tmp/x"] {
            #expect(problemKind(text) == .notAccepted, "expected a refusal")
        }
        // Accepted neighbours.
        for text in ["echo ${x}", "echo ${x:-y}", "echo ${x:=y}", "echo ${x:?y}", "echo ${#x}", "echo $1 $? $$ $@",
                     "[ a = b ]", "[[ $a != b ]]", "if ! true; then :; fi", "echo hi!", "echo 'a!b' \"c!d\"",
                     "echo {a,b} {1..3} {}", "find . -exec rm {} \\;", "echo ~ ~/x", "ls **/*.swift",
                     "echo $HOST:/path", "test ! -f x", "echo a=b", "x= cmd", "echo $((1+2))", "cmd |& cat"] {
            #expect(ShellCommandScanner.scan(text).isReadable, "expected it to be read")
        }
    }

    @Test func unbalancedTextIsRefused() throws {
        #expect(problemKind("echo 'abc") == .unclosedQuote)
        #expect(problemKind("echo \"abc") == .unclosedQuote)
        #expect(problemKind("echo ${x") == .unclosed)
        #expect(problemKind("echo $((1+2)") == .unclosed)
        #expect(problemKind("[[ -f x") == .unclosed)
        #expect(problemKind("case x in a) b;;") == .unclosed)
    }

    // MARK: Limits

    @Test func limits() throws {
        #expect(ShellCommandScanner.scan(String(repeating: "a", count: 4_000)).isReadable)
        #expect(problemKind(String(repeating: "a", count: 4_001)) == .tooLong)
        #expect(ShellCommandScanner.scan(String(repeating: "a ", count: 1_999)).isReadable)
        #expect(problemKind(String(repeating: "a;", count: 1_500)) == .tooManyTokens)
        #expect(ShellCommandScanner.scan(String(repeating: "a;", count: 1_500)).problem?.rule == .b4)
        #expect(problemKind(String(repeating: "( ", count: 40) + "a" + String(repeating: " )", count: 40)) == .tooDeep)
        #expect(ShellCommandScanner.scan(String(repeating: "( ", count: 20) + "a" + String(repeating: " )", count: 20)).isReadable)
        #expect(ShellCommandScanner.scan(String(repeating: "(", count: 40) + "a" + String(repeating: ")", count: 40)).isReadable)
    }

    // MARK: Brace lists

    @Test func braceLists() throws {
        #expect(ShellBraceList.alternatives("{a,b}") == ["a", "b"])
        #expect(ShellBraceList.alternatives("{a,{b,c}}") == ["a", "b", "c"])
        #expect(ShellBraceList.alternatives("{rm,-rf,~}") == ["rm", "-rf", "~"])
        #expect(ShellBraceList.alternatives("{1..3}") == ["1", "2", "3"])
        #expect(ShellBraceList.alternatives("{3..1}") == ["3", "2", "1"])
        #expect(ShellBraceList.alternatives("{01..03}") == ["01", "02", "03"])
        #expect(ShellBraceList.alternatives("{a..c}") == ["a", "b", "c"])
        #expect(ShellBraceList.alternatives("{1..10..4}") == ["1", "5", "9"])
        #expect(ShellBraceList.alternatives("{x}") == nil)
        #expect(ShellBraceList.alternatives("{1..1000}") == nil)
        #expect(ShellBraceList.expand("{1..1000}") == .tooMany)
        #expect(ShellBraceList.expand("{x}") == .notBraceList)
    }
}
