# Security

Pitbox reads private files of the Claude desktop app and can run commands a model wrote, after your click. Reports
about either are welcome. The full model (actors, what is read, the run path, the sandbox, the dock link, every
threat and what is left over) is [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Reporting a vulnerability

Please report privately, through GitHub's private vulnerability reporting: open the repository's **Security** tab and
choose **Report a vulnerability**. Do not open a public issue, pull request or discussion for a vulnerability.

Include what you can: the Pitbox version or commit, the macOS version, what an attacker controls (for example the text
of a session's reply, a file on a server, another app), the steps, and what happens. Please use invented data: never
send real session transcripts, summaries, command output, keys or other private text.

Pitbox is a personal project maintained on a best-effort basis. Reports are read and answered as time allows; a fix
for a confirmed issue in the run path comes first. There is no bug bounty.

## Supported versions

Only the latest commit on `main` is supported. There are no prebuilt releases: you build Pitbox yourself
(see the [README](README.md)), so update by pulling and building again.

## In scope

- **The run path:** the command reader (`PitboxKit`'s scanner and classifier), the run sheet, its arming and its
  checks at the click, the run policy (`"commands": "copyOnly"` must never offer Run), the clean shell and its
  environment, the folder binding, the command helper, the disclaimed spawn, and anything that lets text from a session
  run without your click, run something other than the text you saw, or run it somewhere else.
- **The sandbox profile:** a command reading, writing or connecting to anything under Pitbox's own folder
  (`~/Library/Application Support/Pitbox`, including `dock.sock`), connecting to another app's Unix socket under
  `~/Library/Application Support` (outside `sandboxAllowSocketFolders`), or reaching a folder a dock host announced or
  `sandboxDenyFolders` lists, from inside the command's own process tree.
- **Fetch file:** writing outside `~/Downloads`, replacing a file, a file without quarantine, a name that hides its
  type, using a host, user, option or path the sheet did not show, or bypassing the size and time limits.
- **The dock link:** anything a peer can do through `dock.sock` beyond what [docs/DOCK_PROTOCOL.md](docs/DOCK_PROTOCOL.md)
  §11 allows (geometry, look, focus, fold, the speech pause, announced folders), a crash or hang caused by a peer, or
  session content on the link.
- **The readers of Claude's files and your SSH config:** following a link in Claude's folders or your SSH config,
  blocking on a FIFO, reading outside the fixed roots, touching a network path (`/net`, an automount) for a path a
  session, a reply or a program's output named (write targets, the session's folder, console links), unbounded memory
  or time from a hostile file, running a program while resolving a host name, or session text reaching a log line.
- **Links, previews and opened files:** opening something without your click, a preview that runs scripts or loads
  from the network, a link whose shown host is not the host opened.
- **The window guard:** moving or resizing a window it should leave alone (full-screen, minimized, an exempt app,
  Pitbox's own panels), acting on an app outside its rules, or setting `AXManualAccessibility` other than as
  [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) describes.

## Out of scope

- Malware or any process running as your user. It can do everything you can: edit Pitbox's settings, replace the app,
  post mouse clicks, read Claude's files directly, and pose as a dock host.
- What a command does after you clicked Run on its sheet, within your rights and outside the sandbox's rules. The sheet
  says it cannot tell what a program does.
- Programs a command hands to launchd, Launch Services (`open`), `osascript` or another machine (`ssh`, including
  `ssh localhost`): they run outside the sandbox by design of macOS (documented below; a way to make the sheet warn
  better is welcome as an issue).
- Setuid programs failing in command tabs (a known limit).
- Vulnerabilities in macOS, WebKit, `ssh`/`scp`, zsh, SwiftTerm or the Claude desktop app itself (report those to their
  makers; a Pitbox-specific way to reach them is in scope).
- Denial of service by a dock host you listed yourself.

## The run path's protections, in brief

- **Run is off by default** (`"commands": "copyOnly"`): Copy and Type into terminal only, where Type types the text
  into a fresh shell without pressing Return.
- Only code blocks of a session's latest, completely read reply become offers. Offers of an earlier reply stay for
  at most 24 hours and two newer replies, and run only behind red line **R22** ("the session has moved on since this
  command"), with its own tick. Nothing for another machine ever runs.
- A native sheet that never takes the keyboard, with no default button and no key equivalents, shows the exact text,
  its origin, its folder and machine, and every risk Pitbox recognises; each red line needs its own tick. Run and Fetch file arm
  0.8 s after the sheet's last change (2 s when the command has a red line, so 2 s after the last tick), Type after
  0.8 s, and none of them, nor the fetched file's Open or Open a terminal, under a resting pointer. One click runs the
  frozen text once.
- At the click: the run policy, the offer's freshness, the folder's identity and the write targets are checked again.
- The command runs in a clean `/bin/zsh` (no startup files, a fixed PATH, a fixed environment), started through
  `pitbox-command-helper` as its **own** app for macOS privacy prompts (`responsibility_spawnattrs_setdisclaim`), under
  a Seatbelt profile (`/usr/bin/sandbox-exec`) that denies Pitbox's own folder (`~/Library/Application Support/Pitbox`;
  not its logs, caches or app bundle), every Unix socket under
  `~/Library/Application Support` (with a file-only allow list), the folders a dock host announced and
  `sandboxDenyFolders`, and renaming any parent of those folders. Without the disclaim call, the sandbox tool, a sound
  helper or a buildable profile, nothing starts.
- Logs hold labels and numbers, plus the names of apps whose windows the window guard handled (with window frames),
  your hotkey text and keyboard layout, and macOS's own error descriptions; never session text, commands, paths from
  your sessions, host names, window titles or output.
- No control socket, CLI, URL scheme, scripting or dock message reaches the run path.

## Residual risks, said plainly

- A command you approve runs with your rights: your files, your network, Unix sockets outside
  `~/Library/Application Support`, the Keychain items the `security` tool can read, and your ssh-agent when it runs one
  of the eleven ssh-family programs (always, with `"commandShell": "login"`). One that matches no known pattern runs
  after one click.
- The sandbox covers the command's own process tree only. **A program the command hands to launchd (`launchctl`),
  `open`, `osascript` or another machine (including `ssh localhost` where Remote Login is on) runs outside it**, with
  your rights and without the command's own privacy identity, and could read Pitbox's files or connect to its socket.
- Software that posts mouse events as you can tick and press Run.
- With `"commandShell": "login"` your startup files run before the command. "Open a terminal on <host>" runs your login
  shell and `ssh` as Pitbox, outside the sandbox; Fetch file runs `/usr/bin/scp` as Pitbox, outside the sandbox, with
  its own fixed argument list (a `ProxyCommand` in your SSH config runs then).
- Setuid programs (`sudo`, `ps`, `top`, `crontab`) cannot start in command tabs at all.
- The helper is checked by its file (owner, mode, folder), not by its code signature at run time.
- Pitbox relies on a private Accessibility call (`_AXUIElementGetWindow`), a private spawn attribute
  (`responsibility_spawnattrs_setdisclaim`), a deprecated tool (`/usr/bin/sandbox-exec`) and a private window-server
  call (`CGSSetConnectionProperty`, for the strip's cursors while another app is active). All are looked up at run
  time; without the spawn attribute or the sandbox tool, Run and Type turn off; without the other two, window matching
  is weaker and the pointer stays the arrow. A macOS update can remove any of them.
- The window guard moves other apps' windows that cover the strip, and by default sets `AXManualAccessibility` once on
  an app that lists no windows to Accessibility; that app may use more resources or change behaviour (VS Code may
  switch to its screen-reader mode) until it quits. Exempt it with `PITBOX_GUARD_EXEMPT`, or pause the guard.
- What a command printed stays in its tab until you close the tab. Monitor text is on screen, and Pitbox cannot tell
  when your screen is shared.
