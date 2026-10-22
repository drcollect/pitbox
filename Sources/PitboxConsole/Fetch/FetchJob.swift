import Darwin
import Dispatch
import Foundation
import PitboxKit

/// One started Fetch file, from the checks before connecting to the file in Downloads.
///
/// 1. The plan is checked again against its own rules and its argument list rebuilt (a plan is only what the sheet
///    showed, never trusted as a command); the SSH config must be unchanged since the plan.
/// 2. Downloads is opened once (`O_DIRECTORY | O_NOFOLLOW`) and bound by device and inode; the staging parent must be
///    on the same volume; the volume must keep 5 GB after the 500 MB limit.
/// 3. scp runs (`/bin/sh -c 'ulimit -f … && exec /usr/bin/scp "$@"'`, positional arguments) in its own process group
///    with stdin `/dev/null` and the terminal's environment allowlist, into a new private staging folder.
/// 4. Every 0.5 s: progress, the free space, the size, 30 s to see a first byte staged, 10 minutes in all.
/// 5. Afterwards the staged file is opened `O_NOFOLLOW` (a regular file only), set to 0644 and quarantined (read back),
///    Downloads must still be the same folder, and `renameatx_np(RENAME_EXCL)` moves it in under the first free name.
/// 6. The staging folder, with any partial file, is removed whatever happened. `completion` runs exactly once, on the
///    main thread; `cancel()` after it does nothing.
///
/// All state lives on one serial queue; nothing blocks a thread while scp runs.
final class FetchJob: FetchHandle, @unchecked Sendable {
    private let id: Int
    private let plan: FetchPlan
    private let environment: FetchEnvironment
    private let reader: SSHConfigReader
    private let log: @Sendable (String) -> Void
    private let release: @Sendable () -> Void
    private let queue: DispatchQueue

    // Queue-confined.
    /// The caller's callbacks, dropped when the fetch ends: a caller that keeps the handle while its callbacks capture
    /// it (the sheet) is then not kept alive by the fetch.
    private var progress: (@MainActor (Int64) -> Void)?
    private var completion: (@MainActor (FetchFileOutcome) -> Void)?
    private var finished = false
    private var cancelRequested = false
    private var stopReason: FetchFailure?
    private var child: FetchChildProcess?
    private var timer: DispatchSourceTimer?
    private var downloadsFD: Int32 = -1
    private var parentFD: Int32 = -1
    private var stagingFD: Int32 = -1
    private var stagingName: String?
    private var stagingPath = ""
    private var downloadsIdentity: FolderIdentity?
    private var startedAt = ContinuousClock.now
    private var lastReported: Int64 = -1

    init(id: Int, plan: FetchPlan, environment: FetchEnvironment, reader: SSHConfigReader,
         log: @escaping @Sendable (String) -> Void, progress: @escaping @MainActor (Int64) -> Void,
         completion: @escaping @MainActor (FetchFileOutcome) -> Void, release: @escaping @Sendable () -> Void) {
        self.id = id
        self.plan = plan
        self.environment = environment
        self.reader = reader
        self.log = log
        self.progress = progress
        self.completion = completion
        self.release = release
        self.queue = DispatchQueue(label: "pitbox.console.fetch.run.\(id)")
    }

    private var limits: FetchLimits { environment.limits }

    func begin() { queue.async { [self] in run() } }

    /// Stops scp (SIGKILL to its process group), removes the staging folder and reports `.cancelled`; nothing once the
    /// fetch has ended.
    func cancel() { queue.async { [self] in requestCancel() } }

    // MARK: Before scp

    private func run() {
        startedAt = .now
        guard planStillHolds() else { return fail(.planInvalid) }
        let reading = reader.read()
        guard reading.problem == nil, !reading.hasMatch, reading.hostTokens.contains(plan.alias),
              reading.fingerprint == plan.configFingerprint else { return fail(.configChanged) }

        downloadsFD = FetchFolders.openFolder(environment.downloads)
        guard downloadsFD >= 0, let downloads = FetchFolders.identity(of: downloadsFD) else { return fail(.downloadsUnavailable) }
        downloadsIdentity = downloads
        parentFD = FetchFolders.openStagingParent(environment.stagingParent)
        guard parentFD >= 0, let parent = FetchFolders.identity(of: parentFD) else { return fail(.stagingFailed) }
        guard parent.device == downloads.device else { return fail(.otherVolume) }
        guard let free = environment.freeSpace(downloadsFD), free >= limits.freeSpaceReserve + limits.maxFileBytes else {
            return fail(.notEnoughSpace)
        }
        FetchFolders.sweepStale(in: parentFD, olderThan: limits.staleStagingAge, now: Date())
        guard let staging = FetchFolders.makeStagingFolder(in: parentFD) else { return fail(.stagingFailed) }
        stagingName = staging.name
        stagingFD = staging.fd
        stagingPath = environment.stagingParent + "/" + staging.name
        if cancelRequested { return finish(.cancelled, label: "result=cancelled") }

        let scpArguments = FetchCommand.arguments(user: plan.loginUser, alias: plan.alias, remotePath: plan.remotePath,
                                                  stagingFolder: stagingPath, fileName: plan.fileName,
                                                  connectTimeout: limits.connectTimeoutSeconds,
                                                  extraOptions: environment.extraSCPOptions)
        let arguments = FetchCommand.spawnArguments(scpArguments: scpArguments, maxFileBytes: limits.maxFileBytes)
        do {
            child = try FetchChildProcess.spawn(executable: FetchCommand.shellPath, arguments: arguments,
                                                environment: environment.processEnvironment, captureStdout: false,
                                                workingDirectory: stagingFD, queue: queue) { [self] exit, output in
                childExited(exit, output)
            }
        } catch {
            return fail(.spawnFailed)
        }
        startTimer()
    }

    /// The plan is what the sheet showed, not a command: its fields must pass the same rules again, its login user must
    /// be one it offered, and its argument list must be exactly the one these fields give.
    private func planStillHolds() -> Bool {
        guard FetchNames.isValidAlias(plan.alias), FetchNames.isAcceptableRemotePath(plan.remotePath),
              FetchNames.isAcceptableFileName(plan.fileName) else { return false }
        let asConfigUser = plan.loginUser == plan.configUser && FetchNames.isUsableConfigUser(plan.loginUser)
        let asReplyUser = plan.loginUser == plan.replyUser && FetchNames.isValidReplyUser(plan.loginUser)
        guard asConfigUser || asReplyUser else { return false }
        let expected = FetchCommand.arguments(user: plan.loginUser, alias: plan.alias, remotePath: plan.remotePath,
                                              stagingFolder: FetchCommand.stagingPlaceholder, fileName: plan.fileName,
                                              connectTimeout: limits.connectTimeoutSeconds,
                                              extraOptions: environment.extraSCPOptions)
        return expected == plan.arguments
    }

    // MARK: While scp runs

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + limits.pollInterval, repeating: limits.pollInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [self] in poll() }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        guard !finished, !cancelRequested, stopReason == nil, let child, child.isRunning else { return }
        let elapsed = Self.elapsed(since: startedAt)
        let staged = FetchFolders.stagedSize(in: stagingFD, name: plan.fileName)
        if elapsed >= limits.totalDeadline { return stop(.timedOut) }
        if staged == nil, elapsed >= limits.connectDeadline { return stop(.timedOut) }
        if let size = staged, size > limits.maxFileBytes { return stop(.tooLarge) }
        guard let free = environment.freeSpace(downloadsFD), free >= limits.freeSpaceReserve else { return stop(.spaceRanOut) }
        if let size = staged, size != lastReported, let progress {
            lastReported = size
            DispatchQueue.main.async { MainActor.assumeIsolated { progress(size) } }
        }
    }

    /// Pitbox ends scp for a reason of its own; the exit then reports that reason.
    private func stop(_ reason: FetchFailure) {
        if stopReason == nil { stopReason = reason }
        child?.killGroup()
    }

    private func requestCancel() {
        guard !finished else { return }
        cancelRequested = true
        if let child, child.isRunning {
            child.killGroup()   // the exit reports `.cancelled`
        } else if child == nil {
            finish(.cancelled, label: "result=cancelled")
        }
    }

    // MARK: After scp

    private func childExited(_ exit: ProcessExit, _ output: FetchChildProcess.Output) {
        timer?.cancel()
        timer = nil
        if cancelRequested { return finish(.cancelled, label: "result=cancelled") }
        if let reason = stopReason { return fail(reason) }
        guard exit == .exited(0) else {
            let reason = FetchFailure.classify(exit: exit, stderr: output.stderr, stagingFolder: stagingPath)
            return fail(reason, exit: exit)
        }
        finalize()
    }

    private func finalize() {
        let staged: (fd: Int32, size: Int64)
        switch FetchFolders.openStagedFile(in: stagingFD, name: plan.fileName) {
        case .failure(let reason): return fail(reason)
        case .success(let file): staged = file
        }
        defer { close(staged.fd) }
        guard staged.size <= limits.maxFileBytes else { return fail(.tooLarge) }
        guard fchmod(staged.fd, 0o644) == 0 else { return fail(.permissions) }
        let value = FetchQuarantine.value(at: Date(), id: UUID())
        guard FetchQuarantine.apply(value, to: staged.fd, io: environment.quarantine) else { return fail(.quarantine) }
        // Downloads must still lead to the folder bound at the start; the rename then goes into that descriptor.
        guard let now = FetchFolders.identity(atPath: environment.downloads), now.isFolder,
              now.identity == downloadsIdentity else { return fail(.downloadsChanged) }
        let candidates = FetchNames.candidates(for: plan.fileName)
        switch FetchFolders.moveExclusive(name: plan.fileName, from: stagingFD, to: downloadsFD, candidates: candidates) {
        case .failure(let reason):
            fail(reason)
        case .success(let finalName):
            let copy = (candidates.firstIndex(of: finalName) ?? 0) + 1
            finish(.saved(fileName: finalName, bytes: staged.size),
                   label: "result=saved bytes=\(staged.size) copy=\(copy)")
        }
    }

    // MARK: The end

    private func fail(_ reason: FetchFailure, exit: ProcessExit? = nil) {
        let words = reason.words(alias: plan.alias, user: plan.loginUser, fileName: plan.fileName, limits: limits)
        var label = "result=failed reason=\(reason.rawValue)"
        switch exit {
        case .exited(let code)?: label += " exit=\(code)"
        case .signaled(let signal)?: label += " signal=\(signal)"
        default: break
        }
        finish(.failed(reason: words), label: label)
    }

    private func finish(_ outcome: FetchFileOutcome, label: String) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        child?.killGroup()   // nothing once scp was reaped
        cleanUp()
        release()
        log("fetch finished run=#\(id) \(label) seconds=\(FetchRunner.seconds(since: startedAt))")
        let completion = completion
        self.completion = nil
        progress = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { completion?(outcome) } }
    }

    /// The staging folder goes, with whatever scp left in it (it leaves a partial file behind when the size limit
    /// stops it, measured), and every descriptor is closed.
    private func cleanUp() {
        if stagingFD >= 0 { close(stagingFD); stagingFD = -1 }
        if let name = stagingName, parentFD >= 0 { FetchFolders.removeTree(named: name, in: parentFD) }
        stagingName = nil
        if parentFD >= 0 { close(parentFD); parentFD = -1 }
        if downloadsFD >= 0 { close(downloadsFD); downloadsFD = -1 }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
