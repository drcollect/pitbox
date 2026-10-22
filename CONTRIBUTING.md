# Contributing

Thank you for looking. Pitbox is a personal project maintained on a best-effort basis: issues and pull requests are
read and answered as time allows, and small, focused changes are the easiest to take. For anything larger, or anything
that touches the protected core (below), please open an issue first so we can agree on the approach.

Security problems go through private reporting, never a public issue: see [SECURITY.md](SECURITY.md).

## Sign your commits (DCO)

Pitbox uses the [Developer Certificate of Origin](https://developercertificate.org/) (version 1.1) instead of a
contributor license agreement. There is no CLA. By adding a `Signed-off-by:` line to a commit you certify that you
wrote the change or otherwise have the right to submit it under the project's license (Apache-2.0).

Sign off every commit with `git commit -s`, which adds a line with the name and e-mail address of your git
configuration:

```
Signed-off-by: Your Name <your e-mail address>
```

Forgot one? `git commit --amend -s` for the last commit, or `git rebase --signoff main` for a branch. Pull requests
with unsigned commits will not be merged.

## Build and test

You need macOS 26, the Command Line Tools (or Xcode) and Swift 6.2 or newer. No Xcode project, no third-party tools.

- **Tests:** `scripts/test.sh` builds once and runs each test target in its own process; a target that runs no test
  fails. One target, suite or test: `scripts/test.sh --filter PitboxConsoleTests` (any `swift test` arguments). Run
  several targets one by one rather than in one `--filter 'A|B'`: the real-process suites (pseudo-terminals, `scp`,
  WebKit) are timing-sensitive and can starve each other in one process. The script adds the framework paths a
  Command-Line-Tools-only Mac needs and points Pitbox's state at a scratch folder.
- **The app:** `scripts/build.sh` builds and signs `build/Pitbox.app` (see the README). Use `PITBOX_SCRATCH=<folder>`
  for a separate build folder.
- **Pictures:** some tests render parts of the UI to PNG files when `PITBOX_TEST_OUT=<folder>` is set (and the run
  sheet's when `PITBOX_SHEET_PNG_DIR=<folder>` is set); look at them when you change a view.
- Every change should keep `scripts/test.sh` green with no new compiler warnings, and add tests for new behaviour
  (Swift Testing: `import Testing`, `@Test`, `#expect`; there is no XCTest).

## The scrub check

The repository must never contain private data: real names, e-mail addresses, IP addresses, host names, secrets,
session text or transcripts. Before you open a pull request, run:

```sh
scripts/scrub-check.sh --generic-only
```

It must print `scrub: clean`. It looks for IPv4 and e-mail addresses, chat-workspace ids, and secret shapes (tokens,
keys, private keys) in every tracked and new file and in your commit messages. Test fixtures that need such shapes use
documentation values (RFC 5737 addresses, `example.com`, obviously fake tokens); an exception needs a narrow line in
`scripts/scrub-allow.txt` with a reason, which the maintainer reviews. (The maintainer also runs the check with a
private list of names; you do not need it.)

Tests and fixtures use **invented data only**: invented sessions, folders (`/Users/alex/my project`), hosts
(`buildbox`, `*.example.com`, `*.test`) and companies. Never copy text from your real Claude sessions or files into
the repository, an issue or a pull request.

## The protected core

These parts decide what runs, what a command can reach, and what other windows and apps can do to Pitbox. Changes to
them need the maintainer's review (`.github/CODEOWNERS`), and are reviewed adversarially:

- the run path: `Sources/PitboxConsole/Commands/` (the run sheet, its arming, the run policy, the clean shell's
  environment, the spawn, the sandbox profile in `CommandSandbox.swift` and `SandboxMemory.swift`) and
  `Sources/PitboxConsole/Fetch/`;
- the command reader in `Sources/PitboxKit` (`ShellCommandScanner`, `CommandClassifier` and its rules,
  `CommandPatterns`, the character policy) and its vectors in `Tests/PitboxKitTests/ShellVectors.swift`;
- what becomes an offer and what is resolved for it: `Sources/PitboxSessions/Data/OfferExtraction.swift` and
  `Data/SSHConfig.swift` (it runs `ssh -G`);
- `Sources/PitboxKit/Paths.swift` (the folder the sandbox protects) and `Sources/PitboxConsole/LinkPolicy.swift` (which
  links in the console open, and how);
- the helper: `Sources/pitbox-command-helper/`;
- the window guard: `Sources/PitboxGuard/`;
- the dock link: `Sources/PitboxDock/` and `docs/DOCK_PROTOCOL.md`;
- `scripts/build.sh` and `scripts/make-dev-cert.sh`;
- `Package.swift` and `Package.resolved` (dependencies are pinned exactly; no new third-party dependency without
  agreement first).

A change there should say in its description what it changes about the threat model ([docs/THREAT_MODEL.md](docs/THREAT_MODEL.md))
and update that document in the same pull request.

## Coding conventions, in brief

- **Swift 5 language mode**, macOS 26 APIs; one package, and modules depend only on `PitboxKit` (the app target wires
  them together). Small files; doc comments on public API.
- **UI on the main actor.** Accessibility calls never run on the main thread. Test windows set
  `animationBehavior = .none`, and test helpers do not park GCD threads in blocking calls.
- **No `print`.** Log through `Log` with **labels and numbers**: never session text, commands, paths, hosts, titles,
  URLs or secrets, also not in assertion, precondition or `fatalError` messages. (The window guard's lines name the
  apps whose windows it handled; keep anything else to labels and numbers.)
- **Fail closed.** When a check cannot be made (a file that is not what it should be, a missing system call, a helper
  that fails its check), the feature turns off and says why; it never guesses or falls back to something weaker.
- **Untrusted input stays data.** Everything from Claude's files, transcripts, SSH configuration and the dock link is
  read with limits (no links followed, sizes and nesting bounded, strict JSON) and is never parsed for something to
  run, except by the command reader for the run sheet. No force-unwrapping of external input.
- **Words a person sees** use `AppIdentity.displayName` for the product name, and the pit-stop words ("in the pit",
  "back on track", "Pit all done"); code, file names, settings keys and log labels keep "park".
- **Settings:** a key that changes what runs or what is read is file-only (`CodeSettings.fileOnlyKeys`) and has no
  menu or window control. Document every new key in [docs/SETTINGS.md](docs/SETTINGS.md).
- **Cheap when idle:** no timers while the strip is hidden; file events only mark work as dirty.

## Pull requests

Keep a pull request to one change, describe what and why, and say how you tested it (which `scripts/test.sh` runs,
and anything you checked by hand). The template lists the rest.
