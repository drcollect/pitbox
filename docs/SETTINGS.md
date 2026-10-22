# Settings

Pitbox keeps its settings in one JSON file:

```
~/Library/Application Support/Pitbox/settings.json
```

(The folder moves with the environment variable `PITBOX_APP_SUPPORT`, which the tests use; see
[Environment variables](#environment-variables).) The menu bar item's **Show the settings file** reveals it in Finder.

## How the file is read and written

- **First launch.** When the file is missing, Pitbox writes every key with its default, file-only keys included (mode
  `0600`, an exclusive create that never replaces a file). The same happens when you change a setting in the app while
  the file is missing. An existing file is never rewritten at launch.
- **Reading.** The file is read carefully: a symbolic link is not followed, the file must be a regular file owned by
  you, at most 256 KB, strict JSON with nesting of at most 16, and a key that appears twice fails the whole file. A
  file that fails these checks is not used: at launch Pitbox uses the defaults; while it runs it keeps the last good
  settings and logs `settings: unreadable (<reason>), keeping the last good ones`.
- **Each key on its own.** Unknown keys are ignored (and kept). A key with a wrong type or a value out of range falls
  back to its default without affecting the others; a list or a map keeps its valid entries and drops the rest.
- **Hand edits apply at once.** Pitbox watches the file (and its folder, so an editor's save-by-rename counts) and
  reads it again about 0.25 s after the last change. Exceptions are noted below (`dashboards` needs a restart).
- **Writing.** Pitbox writes the file only when you change something in the menu bar item, the settings window, the
  block's fold button or the fold hotkey, and when the block unfolds itself (for a Run or a Type, or when you hold a
  window over the rail) or a dock host folds it. It reads the file carefully, changes that one key and writes the whole
  object back atomically (`0600`), keeping every other key, unknown ones included. The file is written pretty-printed
  with sorted keys, so your own formatting and key order are not kept. If the read fails, it writes nothing: the
  settings window shows "Can't change: the settings file couldn't be read"; the menu, the fold button and the hotkeys
  beep and log the words.
- **File-only keys.** The keys that change what runs or what is read can only be changed by editing the file:
  `commands`, `commandShell`, `extraPath`, `sandboxDenyFolders`, `sandboxAllowSocketFolders`, `serverNames`,
  `serverTimeZones`, `showText`, `sayHeadlines`, `profiles`, `dashboards` and `dock.hosts`. The app never changes them:
  it only writes their defaults when it creates the file. The settings window shows them read-only.

In the tables below, **Where** says what can change a key: *window* = the settings window (menu bar item ›
Settings…), *menu* = the menu bar item, *file only* = by editing the file (the app never changes it, it only writes the default
into a new file), *file* = no control exists yet, but the app keeps your value when it writes other keys.

## The block

| Key | Type | Default | Allowed values | Where | What it does |
| --- | --- | --- | --- | --- | --- |
| `columns` | integer | `2` | `1`, `2` | window, menu | How many monitor columns the block is wide. When two do not fit (alone: more than half of the display's width; docked: more than the host's limit), Pitbox shows one, then only the fold rail |
| `folded` | boolean | `false` | | fold button (−/+), ⌃⌥C, menu, a dock host; Run, Type and holding a window over the rail unfold it | Folded to the 24 pt rail. Folding stops nothing: sessions are still read, running commands keep running |
| `edge` | string | `"right"` | `"right"`, `"left"` | window, menu | The screen edge when alone. Docked, the host's edge wins |
| `display` | string | `"main"` | `"main"`, or a display's UUID (letters, digits and `-`, at most 64) | window, menu | The display when alone. A display that is not connected means the main display until it comes back |
| `cellWidth` | number | `323` | 300-360 (points) | window | The width of one column when alone. Docked, the host's column width is used |
| `topGap`, `bottomGap` | number | `0` | 0-600 (points; written in whole points) | menu (presets 0, 100, 200, 300, 400) | Space kept free above and below the block when alone |
| `keepAboveWindows` | boolean | `true` | | menu | Alone: above normal windows, or behind them. Docked, the host's level wins |
| `launchAtLogin` | boolean | `false` | | menu | Start Pitbox at login. Pitbox makes the system's login item match this value at launch and after every change |
| `hotkeys` | object | `{"park": "ctrl+opt+p", "fold": "ctrl+opt+c"}` | each 1-64 ASCII characters without spaces, written as below | window | `park`: pit the front Claude pop-out window. `fold`: fold or unfold the block |

**Hotkey text.** ASCII only, no spaces, upper or lower case: words joined by `+`. Modifiers: `ctrl` (or `control`,
`ctl`), `opt` (or `option`, `alt`), `shift`, `cmd` (or `command`), `hyper` (all four) and `meh` (all but cmd). Then
exactly one key: a letter or digit, a named key (`space`, `return` or `enter`, `tab`, `esc`, `delete` or `backspace`,
`forwarddelete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1`-`f20`) or a punctuation
character or its name (`minus`, `equal`, `comma`, `period`, `slash`, `backslash`, `semicolon`, `quote`, `grave`,
`leftbracket`, `rightbracket`, `plus`). Examples: `ctrl+opt+p`, `cmd+shift+f12`. The menu shows shortcuts with the ⌃⌥⇧⌘
symbols, but the file and the settings window take only the words: a value with a symbol or a space is not accepted
(in the file the key falls back to its default; in the window the change is refused).

- A key other than a function key needs `ctrl`, `opt` or `cmd`. `fn` is not supported. The character must be on the
  current keyboard layout.
- These combinations are refused: ⌥Space, ⌘Space, ⌘⌥Space, ⌘Tab, ⌘⇧Tab and ⌘Q.
- A combination that is ASCII but cannot be parsed or registered stays in the file; that shortcut is then off, and the
  menu and the settings window say why ("unavailable: …").
- A combination another app already holds is not taken over: the menu shows "⌃⌥P is taken by another app" and Pitbox
  tries again when the menu opens. A combination that is also a macOS shortcut is registered with a warning (macOS's
  shortcut wins).
- Give `park` and `fold` two different combinations.

## Monitors, Ready and the desk

| Key | Type | Default | Allowed values | Where | What it does |
| --- | --- | --- | --- | --- | --- |
| `look` | string | `"monitors"` | `"monitors"`, `"rows"` | window | Monitors, or slim rows |
| `deskWindows` | string | `"tags"` | `"tags"`, `"monitors"` | window | A pop-out window that is on your desk ("on track") gets a desk tag and Ready items only, or a monitor too. While desk tags are not available (below), desk windows get monitors |
| `deskTags` | boolean | `true` | | window | Desk tags beside matched pop-out windows. **In this version desk tags are not shown** until an attended check of their placement passes (`DeskTagFeasibility.current` in the code is `untested`); they appear only when Pitbox is started with the environment variable `PITBOX_DESKTAG_LAB=1`. The Ready list shows the same items either way |
| `peekDelaySeconds` | number | `1.2` | `0` (off) or 0.3-3 | window (0.4 s, 1.2 s, Off) | How long the pointer rests on a monitor before its peek opens |
| `dragToPark` | boolean | `true` | | window | Drag a Claude pop-out window onto the block to put it in the pit |
| `readyRecentHours` | number | `6` | 0-48 | window (0 or 6) | Besides pop-out windows, the Ready list follows main-window sessions you used in this many hours; `0` means pop-outs only |
| `finishedMinMinutes` | integer | `3` | 0-60 | file | Work shorter than this gets no Finished item |
| `awayRecap` | boolean | `true` | | window (with `recapAfterMinutes`) | The "While you were away" card |
| `recapAfterMinutes` | integer | `15` | 5-120 | window (15, 30, 60) | Minutes without keyboard or mouse input before you count as away |
| `chime` | boolean | `false` | | window | A chime when a session finishes |
| `sayIt` | boolean | `false` | | window | Say "A Code session is done" with the Mac's on-device voice when a session finishes. Docked, Pitbox speaks only when the host allows it (docs/DOCK_PROTOCOL.md §5.12) |
| `sayHeadlines` | boolean | `false` | | file only | With Say it, say "<headline> is done" instead. A headline holding a `neverSay` word, a host's wake word, or hidden or deceptive characters falls back to the generic phrase |
| `neverSay` | list of strings | `[]` | up to 32 entries, each 1-64 characters with at least one letter, no control characters | file | Words the spoken line never says |
| `warnings` | object | `{"stuck": true, "sameFile": true}` | booleans | window | "Looks stuck" warnings (commands failing again and again, or a long silence), and "Same file" warnings (two sessions editing one file) |
| `showText` | object | `{}` | `{"<copy letter>": false}` | file only | `false` hides that Claude copy's text for good: its monitors show the headline and the state only. A letter not listed shows its text. The header's **Hide text** button hides text for all copies until you press it again (not saved) |

## Claude copies, focus, servers and dashboards

| Key | Type | Default | Allowed values | Where | What it does |
| --- | --- | --- | --- | --- | --- |
| `profiles` | list of objects | `[]` | up to 25 entries `{"folder", "letter", "name", "colour"}` | file only | Extra copies of the Claude desktop app, besides the default one (`~/Library/Application Support/Claude`, letter A). `folder`: one folder name directly under `~/Library/Application Support` (not `Claude`, no `/`, no leading `.`); 1-64 characters; `letter`: one capital letter B-Z, unique; `name`: plain text up to 32 characters (default: the folder); `colour`: `"#RRGGBB"` (the `#` may be left out), optional. A copy that runs with `--user-data-dir` pointing at a folder not listed here shows as "Claude ?" and is never read. Applies at once |
| `focusProfiles` | object | `{}` | `{"<focus name>": ["A", "B", …]}`, up to 32 names of 1-32 characters (not `all`) | file | Docked: when the host reports this focus name, only these copies' monitors show. An unknown name shows everything |
| `serverNames` | object | `{}` | `{"<ssh alias>": ["<other name>", …]}` | file only | Other names of a server, per alias from your `~/.ssh/config`, so `scp <name>:file ~/Downloads/` is recognised as the session's own server. Never filled from a reply |
| `serverTimeZones` | object | `{}` | `{"<ssh alias>": "<IANA zone>"}` (an alias of 1-64 letters, digits, `.`, `_`, `-`, not starting with `-`; a zone macOS knows) | file only | The zone in which a time without a zone ("ETA: 14:30") from a session on that server is read. An alias not listed means UTC |
| `dashboards` | list of objects | `[]` (feature off) | up to 8 entries `{"host", "pathPrefix", "handlePattern"}` | file only | Sites whose links in a session's own replies get a ▦ Dashboard button: `https://<host><pathPrefix><handle>/`. `host`: 3-120 characters, at least two labels of 1-63 lower-case letters, digits and `-` (not at a label's start or end), no port; `pathPrefix`: `"/"` (the default) or segments of lower-case letters, digits, `.`, `_` and `-` between slashes (`"/dash/"`), never `.` or `..`, at most 64 characters; `handlePattern`: an optional regular expression of at most 200 characters the whole handle must also match (the handle is always 1-64 of `a-z`, `0-9` and single `-`). **Read at launch only**: restart Pitbox after a change |

## Commands

These keys decide what the run sheet may do. All are file-only. See the README's "Run" section and
[THREAT_MODEL.md](THREAT_MODEL.md) before you change them.

| Key | Type | Default | Allowed values | What it does |
| --- | --- | --- | --- | --- |
| `commands` | string | `"copyOnly"` | `"copyOnly"`, `"run"` (anything else reads as `"copyOnly"`) | `copyOnly`: the sheet offers **Copy** and **Type into terminal (don't run)**; there is no Run button, and every command offer says "Review…" (Fetch offers keep "⤓ Fetch…"). Fetch file stays (it runs Pitbox's own fixed `scp` argument list, never the reply's text). `run`: the sheet also offers Run after review. Read when a sheet opens, while it is open (it can only switch Run off on an open sheet), at the click and once more right before the command starts |
| `commandShell` | string | `"clean"` | `"clean"`, `"login"` | `clean`: `/bin/zsh -f -i -o interactivecomments -o nobanghist`: no startup files, a fixed PATH (below) and a fixed list of environment variables. `login`: `/bin/zsh -l -i`: your startup files run first and can change what a command does (the sheet says so) |
| `extraPath` | list of strings | `[]` | absolute folders | Folders added to the clean shell's fixed PATH (`/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`). An entry that is relative, holds `:`, is a symbolic link, is missing, is not a folder or is writable by group or others is left out without a message |
| `sandboxDenyFolders` | list of strings | `[]` | up to 64 entries, `/…` or `~/…`, at most 1024 bytes each | More folders commands may not read, write or connect to sockets in. Never re-opened by `sandboxAllowSocketFolders` |
| `sandboxAllowSocketFolders` | list of strings | `[]` | same | Folders under `~/Library/Application Support` whose Unix sockets commands may connect to (every other socket there is closed to commands). Never re-opens Pitbox's own folder, a dock host's announced folders or a `sandboxDenyFolders` entry; `~/Library/Application Support` itself or one of its parents is refused |

For both sandbox lists: at each command start an entry is resolved with `realpath(3)`; an entry that is not absolute,
holds a control character, a `"` or a `\`, or has a `..` after the part that exists is left out and logged as a label.
If Pitbox's own folder cannot be written into the sandbox profile safely, nothing starts.

## Docking

| Key | Type | Default | Allowed values | Where | What it does |
| --- | --- | --- | --- | --- | --- |
| `dock.enabled` | boolean | `true` | | window, menu ("Dock with …") | While on (the default), Pitbox listens on `dock.sock` at every launch and refuses every app not in `dock.hosts`. Off: no socket at all, Pitbox stays alone |
| `dock.hosts` | list of strings | `[]` | bundle ids (letters, digits, `-` and `.`, at least two labels, at most 255) | file only | The host apps that may dock, by bundle id, compared exactly. Empty: no app docks. A host that connects without being listed is refused, and the menu names its bundle id |

The protocol, the checks on a connecting host and what a host can and cannot do: [DOCK_PROTOCOL.md](DOCK_PROTOCOL.md).

## The console

| Key | Type | Default | Allowed values | Where | What it does |
| --- | --- | --- | --- | --- | --- |
| `console.fontSize` | number | `12` | 8-32 (points) | window | The console's font size |
| `console.theme` | string | `"system"` | `"system"`, `"light"`, `"dark"` | window | The console's colours |

## Environment variables

A few switches are environment variables, not settings: they apply to one run of the app and are never saved. Quit
Pitbox, then start it with them, for example:

```sh
open --env PITBOX_GUARD_EXEMPT=com.example.editor ~/Applications/Pitbox.app
```

A start at login or from Finder does not carry them.

| Variable | What it does |
| --- | --- |
| `PITBOX_GUARD_EXEMPT` | A comma-separated list of bundle ids whose windows the window guard leaves alone: it never moves them and never reads or changes anything of those apps through Accessibility (added to Pitbox itself and a fixed list of system parts such as the Dock, Spotlight and Control Center). Use it for an app the guard should leave alone, for example one that changes behaviour when the guard asks it for its accessibility tree (README, "What Accessibility is for") |
| `PITBOX_GUARD_DRYRUN` | `1`, `true`, `yes` or `on`: the window guard only logs the corrections it would make, and never moves a window or asks an app for its accessibility tree |
| `PITBOX_DESKTAG_LAB` | `1`: show desk tags although their attended check has not passed (`deskTags` above), and log measurements of them. `PITBOX_DESKTAG_COVER` and `PITBOX_DESKTAG_INSET` try other placements in that mode |
| `PITBOX_APP_SUPPORT` | Another folder for Pitbox's state instead of `~/Library/Application Support/Pitbox`; the logs and caches then move into it too (`logs/`, `caches/`). The tests use it. Pitbox's sandbox protects that folder instead |

Build and test switches (`PITBOX_SIGN_IDENTITY`, `PITBOX_BUNDLE_ID`, `PITBOX_SCRATCH`, `PITBOX_TEST_OUT`,
`PITBOX_SHEET_PNG_DIR`) are described in the README and CONTRIBUTING.md.

## An example

A file that turns Run on, lists one extra Claude copy and one dock host (`com.example.host`), and pins the block to
the left edge:

```json
{
  "columns": 2,
  "edge": "left",
  "commands": "run",
  "profiles": [{ "folder": "Claude-Work", "letter": "B", "name": "Work", "colour": "#3A7BD5" }],
  "dock": { "enabled": true, "hosts": ["com.example.host"] },
  "serverTimeZones": { "buildbox": "UTC" }
}
```

Keys left out keep their defaults; Pitbox adds nothing to a file you wrote until you change a setting in the app.
