# Architecture

Pitbox is one Swift package (`Package.swift`) with one app product, `Pitbox`, and one small helper executable,
`pitbox-command-helper`. It is an accessory app (`LSUIElement`: no Dock icon, no app menu): it lives in its panel at
the screen edge and in its menu bar item. The only third-party dependency is SwiftTerm, pinned to an exact version
([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).

## Targets

| Target | Kind | Depends on | What it holds |
| --- | --- | --- | --- |
| `PitboxKit` | library | nothing | The shared base: `AppIdentity` (the product name and default bundle id), `Paths` (every folder Pitbox uses), `Log` (labels-only logging), `MonotonicClock`, `JSONValue`, `PitboxTheme`, screen geometry, `Edge`, `ReservedRegion` / `ReservedRegionSource` (the rectangle the window guard keeps free), `WindowDropClaims` (the drop-claim registry shared by drag-to-pit and the guard). Also the **command reader**: `ShellCommandScanner`, `CommandClassifier` and its `CommandAnalysis+…` rules, `CommandPatterns`, the character policy, and the command-offer contract (`CommandOffer`, `CommandOfferPresenting`, `CommandOfferFreshnessChecking`) that connects the block to the run sheet. The accepted shell language is [SHELL_LANGUAGE.md](SHELL_LANGUAGE.md) |
| `PitboxSessions` | library | `PitboxKit` | Everything about Claude Code sessions, and the block's content. `Data/`: finds the running Claude copies, reads their session index, session files, pop-out list and transcript tails carefully, derives each session's state and finds command offers (`CodeSessionsEngine`, `CodeSessionsWorker`, `TranscriptReader`, `OfferExtraction`, `CarefulFiles`, `SSHConfig.swift`, `CleanPathPrograms`). `Model/`: `CodeSettings` (the settings file), `CodeMemoryStore`, `CodeStateFiles`, `CodeTuning` (constants). `Tile/`: the monitors view and model. `Buckets/`, `Ready/` (Ready for you), `Finished/` (finish detection, chime, spoken phrase, "While you were away"), `Progress/` (running time, ETA, estimates), `Results/` (links, report files, the script-free web preview), `Warnings/`, `Dashboards/`, `Windows/` (matching sessions to their pop-out windows; pitting and restoring them through Accessibility), `DragToPark/`, `Tags/` (desk tags), `Block/` (`PitboxBlock`, the block's controller), `Settings/` (the settings window) |
| `PitboxConsole` | library | `PitboxKit`, SwiftTerm | The console drawer at the block's bottom and its tabs (SwiftTerm views over a pseudo-terminal). `Commands/`: the **run path**: the run sheet (`CommandSheetController`, `…Model`, `…View`, `…Panel`, `CommandSheetButton`, `CommandArming`), the run policy (`CommandRunPolicy`), the clean shell's environment (`CommandEnvironment.swift`, `CommandLaunchSpec.swift`), the folder binding, the spawn (`CommandSpawner`, `CommandHelperLocator`), the Seatbelt profile (`CommandSandbox`) and `SandboxMemory`, command and Type tabs. `Fetch/`: Fetch file (`FetchRunner`, `FetchJob`, the SSH config reader, the `ssh -G` lookup, staging, names and quarantine) |
| `pitbox-command-helper` | executable | nothing (imports only Darwin) | The exec shim every command and Type tab starts through: it checks its start-status pipe and that it leads a session on a terminal, takes the pty as its controlling terminal, enters the bound folder by descriptor and execs `/bin/zsh` (it refuses any other program). The app bundle carries it at `Contents/MacOS/pitbox-command-helper` |
| `PitboxGuard` | library | `PitboxKit` | The window guard: keeps other regular apps' windows out of the block's rectangle through the Accessibility API, pushing toward the block's window side (by its edge, never by its midpoint), leaving drags, full-screen windows, floating panels, non-regular and exempt apps alone, honouring drop claims, and by default setting `AXManualAccessibility` on an app that lists no windows to Accessibility (THREAT_MODEL.md, "The window guard") |
| `PitboxShell` | library | `PitboxKit` | The panel and its surroundings: `BlockPanelController` (alone or docked placement, fold and unfold, the guard region, the keyboard without activating the app), `BlockGeometry`, `BlockDisplay`, the root view (glass backdrop, block, drawer), `FoldRailView` (the 24 pt rail), the menu bar item (`PitboxMenuBar`, `PitboxMenuState`, its icon), the About panel, the Accessibility onboarding, global hotkeys (Carbon, with an "is it taken" check), the login item, presence (`PresenceProbe`: keyboard/mouse idle time and screen lock) |
| `PitboxDock` | library | `PitboxKit` | Pitbox's (guest) side of the optional dock link with a host app: `DockListener` (the socket), `DockSession` (framing, strict JSON, handshake, liveness), `DockGuest` (state and callbacks), the peer checks and the folder rule. It imports nothing that runs, shows sessions, pits windows or writes settings; `LinkInvariantTests` pins that. The protocol: [DOCK_PROTOCOL.md](DOCK_PROTOCOL.md) |
| `Pitbox` | executable | the six libraries | The composition root (below). `scripts/build.sh` builds `pitbox-command-helper` separately and copies it into the app bundle |

`tools/guard-lab` is a separate single-file program (not a package target) that opens throwaway windows of its own to
check the window guard of a running Pitbox; see the comment at its top.

The libraries never import each other; each depends on `PitboxKit` only. Everything that crosses a module boundary is
a protocol or a type from `PitboxKit`, or a closure the app passes in.

## The composition root (`Sources/Pitbox`)

`main.swift` and `AppDelegate.swift` start `PitboxApp`. `PitboxApp.launch()`:

1. creates the app-support and log folders (0700);
2. takes the single-instance lock (`flock` on `pitbox.lock`); a second Pitbox quits here, before anything else;
3. loads the settings (`SettingsHub`: one file watcher, one lock-protected copy of the settings in force, one write
   path);
4. binds the dock socket when docking is on (`DockWiring.bind`), before any window, so a host can connect at once;
5. installs the Edit menu and builds the panel (`PitboxApp.swift`), then, one function each in
   `PitboxApp+Wiring.swift`: the sessions engine, the console (`ConsoleSeam`: console host, drawer, run sheet, run and
   sandbox policies) and the block; the desk parts (desk tags, drag-to-pit, the spoken line); the panel's wiring; the
   window guard; the hotkeys; the onboarding, the settings window and the menu bar item;
6. starts the settings watcher, makes the system's login item match `launchAtLogin`, starts the block and the desk
   tags, and asks the dock link to show the panel at its first placement (at once when no listed host app runs; within
   1 s otherwise);
7. starts the window guard right away (it waits by itself for the Accessibility permission) and, without the
   permission, asks macOS for it (which adds Pitbox to the Accessibility list) and shows the onboarding.

`terminate()` stops, in this order: the dock link (`bye`, socket removed), drag-to-pit, the desk tags, the window
observer, the block (pending bucket changes written), the memory store, the console, the guard, the panel and the
settings watcher; then it unbinds the hotkeys and closes the settings window, the onboarding and the menu bar item.

## How the parts talk

- **Block and panel.** The panel (`BlockPanelController`) hosts the block's view and the console drawer's view. It
  reports its layout (columns, column width, which side faces the windows, whether the rail shows); the app passes that
  to the block (rows, width, which corner gets the fold button). The panel's rectangle is a `ReservedRegionSource`.
- **Block and run sheet.** The only ways from a session to the run path are `CommandOfferPresenting.present(…)` and
  `presentFetch(…)` (for a file a session handed over on its server), both implemented by `CommandSheetController`:
  they **show a sheet**, nothing else; only a click on the sheet's own button runs a command or a fetch. What happens on
  the sheet comes back as events (copied, typed, started, finished, stopped, fetched, cancelled, refused) that the block
  shows on the offer's line; the rail's blue dot pulses while a command runs. `CommandOfferFreshnessChecking` lets the
  sheet ask the session side, at the click, whether the offer is still offered. `CommandsNoPathTests` checks that nothing public in `PitboxConsole` starts a command or types
  into a tab.
- **Run and the drawer.** A click on Run asks the drawer to show itself; the drawer asks the app to unfold and lay out
  the block, waits for its own layout and 0.35 s, and only then the command starts, at the drawer's size.
- **Window guard.** `WindowGuard` reads the panel's region and keeps other windows out of it. Drag-to-pit and the guard
  share one `WindowDropClaims` registry, so a Claude window you are dropping onto the block is left alone until the
  drop ends (at most 3 s after the mouse-up, 30 s at all).
- **Dock link.** `DockWiring` connects `DockGuest` to the app: a host's placement goes to the panel, the panel's
  rectangle goes back as `area`; the host's look, focus, fold and wake words go to the panel and the block; the host's
  announced private folders go to `SandboxMemory`; drop claims are mirrored to the host through
  `WindowDropClaims.onChange`; the spoken line asks the host before it speaks. Nothing from the link reaches the run
  path ([DOCK_PROTOCOL.md](DOCK_PROTOCOL.md) §11).
- **Settings.** `PitboxApp.apply(old:new:)` (`PitboxApp+Runtime.swift`, installed as the hub's `onChange`) hands each
  part what concerns it: the block (and through it the engine and drag-to-pit), the desk tags, the console (run policy,
  shell, sandbox lists, font), the hotkeys, the dock link, the panel, the login item, the settings window and the
  menu. [SETTINGS.md](SETTINGS.md) lists every key.

## Files Pitbox writes

Pitbox writes into three folders of yours: `~/Library/Application Support/Pitbox/` and `~/Library/Logs/Pitbox/`, both
made private (0700) at every launch, and `~/Library/Caches/Pitbox/`, whose `fetch/` staging folders are 0700 too. With
`PITBOX_APP_SUPPORT` set, all three move: the state into that folder, the logs and caches into its `logs/` and
`caches/`. Commands Pitbox runs cannot read, write or
connect to anything in the first one (the sandbox profile, [THREAT_MODEL.md](THREAT_MODEL.md)); the logs and caches
folders are not in that profile.

| File | Written by | Holds |
| --- | --- | --- |
| `settings.json` | `CodeSettings` (defaults once; then only the menu, the settings window and fold) | Your settings ([SETTINGS.md](SETTINGS.md)) |
| `code-buckets.json` | `CodeBucketStore` with `CodeBucketWriter` (at most once a second, atomically, 0600) | Bucket names, colours and folded state, which session sits in which bucket, first-seen and last-seen times. Entries not seen for 30 days go; at most 500 entries |
| `code-memory.json` | `CodeMemoryStore` (atomically, 0600) | Per session id: Ready item states (later, dismissed), finished records, seen times, stated ETAs, pending background tasks (hashed task ids), silenced warnings, dashboard handles and the dashboard scan's mark. No titles, summaries, commands, paths, URLs or file names. Pruned after 14 days without activity; at most 200 sessions |
| `code-monitors.json` | the parker (atomically, 0600) | The windows in the pit: copy letter, session id, pid, window number, the frame before pitting, display id, time. No titles or text |
| `block-state.json` | the block | `{"pitHintShown": true}` once the one-time "In the pit" hint was shown |
| `sandbox-memory.json` | `SandboxMemory` (append-only, rewritten whole and atomically, 0600) | The private folders and socket folders verified dock hosts announced; commands stay denied there, also after the host quits |
| `console-state.json` | (not written) | The console's tab list in the terminal mode the code keeps from its origin; Pitbox's console never reads or writes it |
| `pitbox.lock` | `SingleInstanceLock` | Nothing; held with `flock` while Pitbox runs |
| `dock.sock` | `DockListener` | The dock link's Unix socket (0600), only while docking is on; removed at quit and when docking is turned off. It is created under a temporary name (`.dock-<pid>`) and renamed |
| `code-buckets.json.corrupt`, `code-memory.json.corrupt` | the bucket and memory stores | A file that failed its careful read is moved aside under this name, and that part starts fresh. A bad `settings.json`, `code-monitors.json` or `block-state.json` is left in place (and not used) |
| `sandbox-memory.json.broken` | `SandboxMemory` | A file that failed its careful read is moved aside at the next write; the folders Pitbox already knew are kept, nothing is forgotten |
| `.<file>.<hex>.tmp`, `.code-monitors.<UUID>.tmp`, `.sandbox-memory.json.<…>.tmp` | the atomic writers | Temporary files of an atomic write; one can be left behind by a crash in the middle of a write |
| `~/Library/Logs/Pitbox/pitbox.log` (and `pitbox.log.1`) | `Log` | Labels and numbers, plus the names of apps whose windows the guard handled (with frames), hotkey text and keyboard layout, and macOS error descriptions; never session text, commands, session paths, hosts or titles (THREAT_MODEL.md, "Logs"). Rotated at about 2 MB. The same lines go to the unified log (subsystem `io.github.drcollect.pitbox`) |
| `~/Library/Caches/Pitbox/fetch/fetch-<random>/` | Fetch file | A private staging folder (0700) per fetch; removed after every fetch, and leftovers older than 20 minutes are swept |
| `~/Library/Caches/Pitbox/ContentRuleLists/` | the web preview | WebKit's compiled rule list that blocks every network load in the preview |

Outside these folders Pitbox changes only: a fetched file in `~/Downloads` (a new file, never a replacement,
quarantined) when you click Fetch file; the system's login item, which Pitbox makes match `launchAtLogin` at every
launch and after each change; the Accessibility list, to which macOS adds Pitbox when Pitbox asks for the permission
at launch; `AXManualAccessibility` in an app the window guard asks for its accessibility tree (THREAT_MODEL.md, "The
window guard"); and whatever a command you run writes. Whether macOS or WebKit keep state of their own for the app
(preferences, saved window state, WebKit's folders) was not checked.

## Threads and queues

- **Main thread:** AppKit, the panel, the block's models and views, the run sheet, the menu, the settings hub.
- **Sessions:** one serial queue (`pitbox.code.sessions`) does the reading of Claude's files and the derivation. File
  system events only mark sessions dirty; while the block is visible a dirty session is parsed at most once every 2 s,
  and nothing runs on a timer while it is hidden. Smaller queues: the memory store, the bucket writer, the settings
  watcher, and three that also read Claude's files: the offer freshness check (`pitbox.code.freshness`), result checks
  and the one-time dashboard scan.
- **Accessibility:** the window guard has its own thread with a run loop (`pitbox.guard`); the parker's window
  matching and every pit and restore run on another dedicated thread; the desk tags' window observer on a third. No
  call on another app's windows runs on the main thread (only the permission check `AXIsProcessTrusted` does).
- **Dock link:** a listener queue and one serial queue per link, with non-blocking sockets and dispatch sources; no
  thread ever blocks on the link.
- **Console:** one queue per pseudo-terminal, a start watcher for command spawns, and the Fetch file queues (plan, SSH
  lookup, one per running fetch).
- **Log:** one queue writes the log file.

## Where to start reading

1. `Sources/Pitbox/PitboxApp.swift` (`launch()`), then `PitboxApp+Wiring.swift`: what exists and who talks to whom.
2. `Sources/PitboxSessions/Block/PitboxBlock.swift` and `Data/CodeSessionsEngine.swift`: from Claude's files to a
   monitor.
3. The run path, in this order: `PitboxKit/CommandClassifier.swift`, `PitboxConsole/Commands/CommandSheetController.swift`,
   `CommandRunPolicy.swift`, `CommandSpawner.swift`, `CommandSandbox.swift`, `Sources/pitbox-command-helper/main.swift`;
   then [THREAT_MODEL.md](THREAT_MODEL.md).
4. `Sources/PitboxGuard/GuardEngine.swift` and `Placement.swift` for the window guard.
5. `Sources/PitboxDock/DockGuest.swift` with [DOCK_PROTOCOL.md](DOCK_PROTOCOL.md).

The tests (`Tests/<Target>Tests`, Swift Testing) use invented sessions and files only; `scripts/test.sh` runs each
test target in its own process.
