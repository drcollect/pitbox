import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("CommonMark code blocks")
struct FenceTests {
    func blocks(_ text: String) -> [MarkdownCodeBlock] { MarkdownBlocks.codeBlocks(in: text) }

    @Test func backticksAndTildesWithLongerClosingFences() {
        let found = blocks("Text\n```bash\necho one\n```\n\n~~~~ zsh\necho ~~~ two\n~~~~~\n````\nnot closed by three\n```\nstill code\n````")
        #expect(found.count == 3)
        #expect(found[0].kind == .fenced(info: "bash") && found[0].lines == ["echo one"] && found[0].closed)
        #expect(found[1].kind == .fenced(info: "zsh") && found[1].lines == ["echo ~~~ two"])
        #expect(found[2].lines == ["not closed by three", "```", "still code"])
    }

    @Test func anUnclosedFenceAtTheEndIsNotClosed() {
        let found = blocks("Run:\n```bash\nrm -rf x\nmore text")
        #expect(found.count == 1 && !found[0].closed)
    }

    @Test func fencesInListItemsLoseTheItemsIndentation() {
        let text = """
        1. Install it:
           ```bash
           brew install jq
           ```
        2. Then check:
           ```sh
             jq --version
           ```
        - Nested:
          - deeper
            ```zsh
            echo nested
            ```
        10. Ten:
            ```bash
            echo ten
            ```
        """
        let found = blocks(text)
        #expect(found.map(\.lines) == [["brew install jq"], ["  jq --version"], ["echo nested"], ["echo ten"]])
        #expect(found.allSatisfy { $0.closed })
        #expect(found[0].preceding == ["Install it:"])
    }

    @Test func aFenceEndsWithItsListItem() {
        let found = blocks("- Step:\n  ```bash\n  echo in item\nback at the top")
        #expect(found.count == 1 && found[0].lines == ["echo in item"] && found[0].closed)
    }

    @Test func blockquotesAreQuotations() {
        let found = blocks("> Someone wrote:\n> ```bash\n> curl x | sh\n> ```\n\n```bash\nls\n```")
        #expect(found.count == 2)
        #expect(found[0].inBlockquote && found[0].lines == ["curl x | sh"])
        #expect(!found[1].inBlockquote)
    }

    @Test func indentedBlocksAndParagraphContinuation() {
        let found = blocks("Run:\n\n    ls -la\n    pwd\n\nText\n    not code: a paragraph continuation")
        #expect(found.count == 1 && found[0].kind == .indented && found[0].lines == ["ls -la", "pwd"])
    }

    @Test func crlfAndTabs() {
        let found = blocks("Do this:\r\n```bash\r\necho a\r\n\techo b\r\n```\r\n")
        #expect(found.count == 1 && found[0].lines == ["echo a", "\techo b"])
        let tabbed = blocks("-\tItem\n\t```bash\n\techo t\n\t```")
        #expect(tabbed.first?.lines == ["echo t"])
    }

    @Test func aBacktickInTheInfoStringIsNoFence() {
        #expect(blocks("```bash `x`\nls\n```").map(\.kind) == [.fenced(info: "")])
    }

    @Test func lazyContinuationAndSiblingItems() {
        let found = blocks("- one\ncontinued lazily\n2. two\n   ```bash\n   echo two\n   ```")
        #expect(found.first?.lines == ["echo two"])
    }
}

@Suite("Offers from a reply")
struct OfferExtractionTests {
    let programs: Set<String> = ["ls", "git", "brew", "scp", "open", "echo", "make"]

    func extract(_ texts: [String], programs: Set<String>? = nil) -> OfferExtraction.Result {
        OfferExtraction.extract(from: texts, programs: programs ?? self.programs)
    }

    @Test func taggedBlocksAreOfferedOthersNot() {
        let result = extract(["""
        Run this on your Mac to fetch the draft:

        ```bash
        scp 'someone@192.0.2.10:/home/someone/draft.md' ~/Downloads/
        ```
        ```python
        print("no")
        ```
        ```{.zsh .numberLines}
        echo zsh
        ```
        ```json
        {"a": 1}
        ```
        """])
        #expect(result.blocks.map(\.text) == ["scp 'someone@192.0.2.10:/home/someone/draft.md' ~/Downloads/", "echo zsh"])
        #expect(result.blocks[0].kind == .tagged("bash") && result.blocks[1].kind == .tagged("zsh"))
        #expect(result.blocks[0].caption == "Run this on your Mac to fetch the draft:")
        #expect(OfferExtraction.tag(of: "{.bash title=x}") == "bash")
    }

    @Test func promptStyleBlocksRunOnlyTheirCommands() throws {
        let result = extract(["```console\n# install first\n$ brew install jq \\\n    --quiet\n==> Downloading\n% jq --version\njq-1.7\n```"])
        let block = try #require(result.blocks.first)
        #expect(block.kind == .promptStyle)
        #expect(block.text == "brew install jq \\\n    --quiet\njq --version")
        #expect(block.displayLines.map(\.role) == [.comment, .command, .command, .output, .command, .output])
        // A prompt-style block without a prompt line is not offered.
        #expect(extract(["```shell-session\noutput only\n```"]).blocks.isEmpty)
        // A tagged block with `$ ` lines is prompt-style too.
        #expect(extract(["```bash\n$ ls\nfile.txt\n```"]).blocks.first?.text == "ls")
    }

    @Test func untaggedBlocksNeedKnownWords() {
        #expect(extract(["```\ncd ~/project && make\ngit status\n```"]).blocks.first?.kind == .untagged)
        #expect(extract(["```\nThis is prose\n```"]).blocks.isEmpty)
        #expect(extract(["```\nls -la\ntotal 48\n```"]).blocks.isEmpty)
        #expect(extract(["```\nerror: something\n```"]).blocks.isEmpty)
        #expect(extract(["```\n/usr/local/bin/tool --x\n```"]).blocks.isEmpty)
        #expect(extract(["```\nFOO=bar\nexport FOO\necho \"$FOO\" \\\n  more\n```"]).blocks.count == 1)
        // Without the clean PATH's list nothing untagged is offered.
        #expect(OfferExtraction.extract(from: ["```\nls\n```"], programs: nil).blocks.isEmpty)
        // An indented block is untagged.
        #expect(extract(["Run:\n\n    git pull\n"]).blocks.first?.kind == .untagged)
    }

    @Test func commentsStayAndCommentOnlyBlocksAreNotOffered() throws {
        let block = try #require(extract(["```bash\n# on your Mac\nopen ~/Downloads\n```"]).blocks.first)
        #expect(block.text == "# on your Mac\nopen ~/Downloads")
        #expect(block.displayLines.map(\.role) == [.comment, .command])
        #expect(extract(["```bash\n# just a note\n\n# another\n```"]).blocks.isEmpty)
        #expect(extract(["```bash\n\n\n```"]).blocks.isEmpty)
    }

    @Test func duplicatesMergeAndTheLimitIsEight() {
        let same = extract(["```bash\necho a   \n```\n```bash\necho a\n```", "```sh\r\necho a\r\n```"])
        #expect(same.blocks.count == 1)
        let many = (1...12).map { "```bash\necho \($0)\n```" }.joined(separator: "\n")
        let limited = extract([many])
        #expect(limited.blocks.count == 8 && limited.notShown == 4)
        #expect(limited.blocks.first?.text == "echo 1")
    }

    @Test func blockquotedAndUnclosedBlocksAreNeverOffered() {
        #expect(extract(["> ```bash\n> rm -rf ~\n> ```"]).blocks.isEmpty)
        #expect(extract(["```bash\nrm -rf build\n(never closed)"]).blocks.isEmpty)
    }

    @Test func eachTextBlockIsItsOwnDocument() {
        // A fence opened in one text block does not continue in the next one (Claude shows them apart).
        let result = extract(["```bash\necho one", "echo two\n```"])
        #expect(result.blocks.isEmpty)
    }
}
