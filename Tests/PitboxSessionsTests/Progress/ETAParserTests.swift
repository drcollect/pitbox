import Foundation
import Testing
@testable import PitboxSessions

/// The ETA parser's vectors: made up in the shapes measured in real transcripts.
@Suite("ETA parser")
struct ETAParserTests {
    let context = ETAParser.Context(headline: "Toy Cube build", nickname: "quiet fern")

    func value(_ text: String) -> ETAParser.Statement? { ETAParser.statement(in: text, context: context) }

    struct Vector: CustomTestStringConvertible, Sendable {
        var text: String
        var hour: Int
        var minute: Int
        var utc: Bool
        var form: ETAParser.Statement.Form
        var testDescription: String { text }
    }

    static let accepted: [Vector] = [
        Vector(text: "ETA: 23:24", hour: 23, minute: 24, utc: false, form: .rule),
        Vector(text: "ETA:23:24", hour: 23, minute: 24, utc: false, form: .rule),
        Vector(text: "ETA: 9:05", hour: 9, minute: 5, utc: false, form: .rule),
        Vector(text: "ETA: 23:24 UTC", hour: 23, minute: 24, utc: true, form: .rule),
        Vector(text: "Started the build. ETA: 22:24Z", hour: 22, minute: 24, utc: true, form: .rule),
        Vector(text: "ETA ~23:24", hour: 23, minute: 24, utc: false, form: .labelled),
        Vector(text: "ETA (UTC): ~22:24", hour: 22, minute: 24, utc: true, form: .labelled),
        Vector(text: "**ETA:** about 22:10", hour: 22, minute: 10, utc: false, form: .labelled),
        Vector(text: "ETA for the build ~23:24", hour: 23, minute: 24, utc: false, form: .labelled),
        Vector(text: "ETA around 23:00", hour: 23, minute: 0, utc: false, form: .labelled),
        Vector(text: "ETA 22:10-22:40", hour: 22, minute: 40, utc: false, form: .labelled),
        Vector(text: "ETA 22:10 – 22:40", hour: 22, minute: 40, utc: false, form: .labelled),
        Vector(text: "ETA ~22:24 (UTC; it's 22:10 now)", hour: 22, minute: 24, utc: true, form: .labelled),
        Vector(text: "ETA (UTC; it's 22:10 now): ~22:24", hour: 22, minute: 24, utc: true, form: .labelled),
        Vector(text: "ETA 22:24 GMT, give or take", hour: 22, minute: 24, utc: true, form: .labelled),
        Vector(text: "- ETA: 23:24 (local time)", hour: 23, minute: 24, utc: false, form: .rule),
        Vector(text: "ETA approx. 22:40 for the reviews", hour: 22, minute: 40, utc: false, form: .labelled),
        Vector(text: "ETA for 2 agents left, ~22:40", hour: 22, minute: 40, utc: false, form: .labelled),
        Vector(text: "ETA (UTC):\n\n- whole run: ~22:24", hour: 22, minute: 24, utc: true, form: .labelled),
        Vector(text: "**ETA (UTC):**\n- K1: done\n- K2: about 23:05", hour: 23, minute: 5, utc: true, form: .labelled),
    ]

    @Test(arguments: accepted)
    func acceptedShapes(_ vector: Vector) throws {
        let statement = try #require(value(vector.text))
        #expect(statement.value == ETAClockValue(hour: vector.hour, minute: vector.minute, utc: vector.utc))
        #expect(statement.form == vector.form)
    }

    static let refused: [String] = [
        "```\nETA: 23:24\n```",
        "~~~ text\nETA: 23:24\n~~~",
        "Plan:\n\n    ETA: 23:24",
        "- step one\n  ```bash\n  echo ETA: 23:24\n  ```",
        "`ETA: 23:24`",
        "ETA: `23:24`",
        "> ETA: 23:24",
        "> The old note said\nETA: 23:24 lazily",
        "\"ETA: 23:24\"",
        "He wrote “ETA: 23:24” yesterday",
        "ETA: HH:MM",
        "ETA: 24:00",
        "ETA: 23:60",
        "BETA: 23:24",
        "ETA 23:24 PST",
        "ETA 23:24 UTC+1",
        "ETA tomorrow 09:00",
        "ETA 09:00 tomorrow",
        "ETA Mon 09:00",
        "ETA 11:24 pm",
        "ETA: 11:24PM",
        "ETA ~20 min",
        "ETA 20-30 min",
        "ETA: done",
        "ETA ✅",
        "ETA soon",
        "ETA: after the review",
        "No ETA yet. The build started at 22:10.",
        "ETAs: 22:10, 22:40",
        "The ETA depends on the review; the last run ended 22:10.",
        "ETA 2026-10-21 09:00",
        "ETA 21/10 09:00",
        "ETA: 23:24 Lisbon time",
    ]

    @Test(arguments: refused)
    func nothingFrom(_ text: String) {
        #expect(value(text) == nil, "\(text)")
    }

    @Test func usersFormIsPreferredAndTheLastOfAFormWins() throws {
        let both = try #require(value("ETA: 23:24 for the merge.\nETA for the docs ~23:50"))
        #expect(both.form == .rule && both.value.hour == 23 && both.value.minute == 24)
        let twice = try #require(value("ETA: 22:10\nRevised: ETA: 22:45"))
        #expect(twice.value.hour == 22 && twice.value.minute == 45)
        let labelled = try #require(value("ETA ~22:10, then the docs. Overall ETA around 22:50"))
        #expect(labelled.value.minute == 50)
    }

    @Test func tablesCountOnlyWhenUnambiguous() throws {
        let oneRow = """
        | Task | ETA (UTC) |
        |---|:---:|
        | K1 build | ~22:24 |
        """
        let single = try #require(value(oneRow))
        #expect(single.form == .table && single.value == ETAClockValue(hour: 22, minute: 24, utc: true))

        let fleet = """
        | Session | Status | ETA |
        | --- | --- | --- |
        | polar-shore | running | ~22:40 |
        | **quiet-fern** | running | about 23:10 |
        | amber-reef | done | ✅ |
        """
        let own = try #require(value(fleet))
        #expect(own.value == ETAClockValue(hour: 23, minute: 10, utc: false))

        let byHeadline = """
        | Work | ETA |
        |---|---|
        | Other thing | 21:00 |
        | **Toy Cube build** | 21:30 |
        """
        #expect(value(byHeadline)?.value.minute == 30)

        let unclear = """
        Overall ETA for the run ~23:30.

        | Task | ETA |
        |---|---|
        | A | ~22:40 |
        | B | ~23:10 |
        """
        let fallback = try #require(value(unclear))
        #expect(fallback.form == .labelled && fallback.value.minute == 30, "a labelled ETA in the same reply is used")
        #expect(value("| Task | ETA |\n|---|---|\n| A | ~22:40 |\n| B | ~23:10 |") == nil)
        #expect(value("| Task | ETA |\n|---|---|\n| K1 | ✅ done |") == nil, "that row is done")
        #expect(value("```\n| Task | ETA |\n|---|---|\n| K1 | 22:40 |\n```") == nil)
        #expect(value("| Task | ETA (PST) |\n|---|---|\n| K1 | 22:40 |") == nil, "a foreign zone voids the column")
    }

    @Test func tableRowsAreNeverReadAsInlineStatements() {
        // A body cell saying "ETA ~22:40" belongs to its row: with several rows and no own row, nothing.
        let text = "| Task | Note |\n|---|---|\n| A | ETA ~22:40 |\n| B | ETA ~23:10 |"
        #expect(value(text) == nil)
    }

    @Test func textsWithoutTheLabelAreNotParsed() {
        #expect(!ETAParser.mayHoldLabel("Done: 4 of 6 agents, next at 22:40"))
        #expect(ETAParser.mayHoldLabel("…ETA"))
        #expect(value(String(repeating: "lorem ipsum 22:40 ", count: 2000)) == nil)
    }
}
