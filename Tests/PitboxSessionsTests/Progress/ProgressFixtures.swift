import Darwin
import Foundation
@testable import PitboxSessions
import PitboxKit

// Invented data only, in the measured shapes: no line of the user's transcripts appears here.

let utcZone = TimeZone(identifier: "UTC")!
let lisbonZone = TimeZone(identifier: "Europe/Lisbon")!

/// A date from its UTC parts.
func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

/// 24-hour clocks in UTC and in Lisbon (the example zone of these tests).
let clockUTC = CodeClockFormat(timeZone: utcZone, uses24Hour: true)
let clockLisbon = CodeClockFormat(timeZone: lisbonZone, uses24Hour: true)

/// A session snapshot for the derivers and the words.
func progressSnapshot(_ id: String = sessionA, index: Int = 3, state: CodeSessionState = .working,
                      place: CommandSessionFacts.Place = .local, sshHost: String? = nil, headline: String = "Toy Cube build",
                      nickname: String? = "quiet fern", todos: CodeSessionTodos? = nil) -> CodeSessionSnapshot {
    CodeSessionSnapshot(id: id, index: index, profile: .a, headline: headline, nickname: nickname,
                        title: "\(headline) (\(nickname ?? "x y"))", place: place, sshHost: sshHost, state: state,
                        todos: todos)
}

/// A memory store in a fresh folder with the test's clock (so its expiry follows the same time as the deriver).
final class ProgressMemory: @unchecked Sendable {
    let folder = SeamFolder("progress-memory")
    let clock: ManualClock
    let store: CodeMemoryStore

    init(clock: ManualClock) {
        self.clock = clock
        let url = folder.file("code-memory.json")
        store = CodeMemoryStore(url: url, owner: getuid(), clock: { clock.now }, writeInterval: 0.05,
                                writeMax: CodeTuning.memoryWriteMax)
    }

    /// A new store on the same file: a restart of the app
    func restarted() -> CodeMemoryStore {
        store.flush()
        let clock = self.clock
        return CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now },
                               writeInterval: 0.05, writeMax: CodeTuning.memoryWriteMax)
    }
}

/// The input a deriver gets, built by hand.
func deriveInput(_ snapshot: CodeSessionSnapshot, digest: CodeTurnDigest, now: Date, memory: CodeMemoryStore,
                 settings: CodeSettings = CodeSettings(), version: Int = 1, transcript: CarefulPath? = nil) -> CodeDeriveInput {
    CodeDeriveInput(snapshot: snapshot, digest: digest, digestVersion: version, now: now, memory: memory,
                    settings: settings, transcript: transcript, sessionFile: nil, owner: getuid())
}

/// Runs `deriver` once and returns the fields.
func derived(_ deriver: CodeSessionDeriver, _ input: CodeDeriveInput) -> CodeDerivedFields {
    var fields = CodeDerivedFields()
    deriver.derive(input, into: &fields)
    return fields
}

/// Transcript lines of background work, in their measured shapes.
enum TaskLine {
    /// An Agent call in the background and its `async_launched` result.
    static func agentLaunch(_ n: Int, at: Date, subagent: String = "general-purpose") -> [String] {
        [SeamLine.agent(subagent, id: "toolu_ag\(n)", uuid: "ag-use-\(n)", at: at, prompt: "Do part \(n) \(secretWord)"),
         SeamLine.result("toolu_ag\(n)", uuid: "ag-res-\(n)", at: at, content: "Async agent launched",
                         toolUseResult: ["status": "async_launched", "agentId": "agent\(n)x", "isAsync": true])]
    }

    /// A Workflow call and its `async_launched` result.
    static func workflowLaunch(_ n: Int, at: Date) -> [String] {
        [Line.toolUse("Workflow", id: "toolu_wf\(n)", uuid: "wf-use-\(n)", at: at, input: ["scriptPath": "/x/\(secretWord).js"]),
         SeamLine.result("toolu_wf\(n)", uuid: "wf-res-\(n)", at: at, content: "Workflow launched",
                         toolUseResult: ["status": "async_launched", "taskType": "local_workflow", "taskId": "wf\(n)task",
                                         "runId": "run\(n)"])]
    }

    /// A background Bash run (never a task: dev servers never end).
    static func bashLaunch(_ n: Int, at: Date) -> [String] {
        [SeamLine.bash("npm run dev", description: "dev server", id: "toolu_bg\(n)", uuid: "bg-use-\(n)", at: at, background: true),
         SeamLine.result("toolu_bg\(n)", uuid: "bg-res-\(n)", at: at, content: "Started",
                         toolUseResult: ["backgroundTaskId": "bash\(n)", "stdout": "", "stderr": "", "interrupted": false])]
    }
}
