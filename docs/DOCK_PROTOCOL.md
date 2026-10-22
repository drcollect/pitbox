# Dock protocol, version 1.0

This document is the single source for the dock link between Pitbox and a dock host. Both sides implement it from
this text; neither side links code of the other. Pitbox's side lives in `Sources/PitboxDock` (the guest). A host app
implements its side in its own code and names the protocol version it implements in its `hello.build` and in its own
documentation.

The words **must**, **must not**, **should** and **may** are used as in RFC 2119.

## 1. In plain words

- **Pitbox** can run alone at a screen edge, or **docked** beside another app's edge strip, the **dock host** (or
  **host app**). Docked, the two read as one surface: Pitbox sits on the host's window side, exactly as tall as the
  host's strip, and follows the host's light/dark look.
- The two apps talk over **one local Unix socket**. Pitbox listens; the host connects.
- The host tells Pitbox where its strip is, how it looks, its focus, when to fold, and whether Pitbox may speak now.
  Pitbox tells the host the rectangle it took, a few counts, and "leave this window alone for a moment" while you drop
  a window on Pitbox.
- **Nothing on the link can show session content, run a command, type, open, approve or read anything** (section 11).
- Each app works fully when the other is absent, old, hung or crashed.

Words used below: **guest** = Pitbox; **host** = the dock host; **link** = one connection between them; **line** = one
JSON object followed by a newline; **side** = guest or host.

## 2. Transport

### 2.1 The socket

- One Unix domain **stream** socket at `~/Library/Application Support/Pitbox/dock.sock` (the folder moves with the
  environment variable `PITBOX_APP_SUPPORT`, which tests use). The socket file is mode `0600`; its folder is mode
  `0700` and owned by the user.
- **The guest listens; the host connects.** The host adds no listening socket of its own for the dock.
- The guest takes its single-instance lock (`flock` on a file in the same folder) and then, while docking is on, binds
  `dock.sock` and **starts accepting first thing at launch, before any window and before any other start-up work**.
  A second copy of the guest finds the lock taken and quits; it never touches the socket. While docking is off the
  guest has no socket at all (section 2.3).
- The guest creates the socket under a temporary name in the same private folder, sets it to `0600`, starts listening
  and then renames it to `dock.sock`, so the name never shows a wider mode.
- A leftover `dock.sock` is removed **only after a connect to it failed** (`ECONNREFUSED` or `ENOENT`: no live
  listener). A socket that accepts the connect (or reports a full backlog) is live and is never removed: binding then
  fails. Anything at the path that is not a socket (a file, a symlink, a folder) is never removed: binding fails.
- On a normal quit the guest removes the socket, but only while the file at the path is still the one it bound (same
  device and inode).
- Both sides open their sockets close-on-exec and with `SO_NOSIGPIPE`, and use non-blocking I/O; neither side ever
  blocks a thread on the link (a peer that stops reading must not stall the other app).

### 2.2 Who may connect, and how each side checks the other

Same-user software can fake every check below; the security model already puts it out of scope, and section 11 keeps
the link harmless anyway. The checks keep honest mistakes and unrelated apps out.

The **guest** accepts a connection only when all of these hold, checked right after `accept`:

1. **Same user:** `getpeereid` gives the guest's own uid.
2. **A process:** `LOCAL_PEERPID` gives the peer's pid, and the process's start time can be read
   (`proc_pidinfo`, `PROC_PIDTBSDINFO`). The guest records the start time with the pid and compares it again when it
   starts watching the process, so a recycled pid is never taken for the same process. A peer whose start time cannot
   be read is refused.
3. **An app of the user:** the process's executable (`proc_pidpath`) is a regular file directly in
   `<name>.app/Contents/MacOS/`, and both the `.app` folder and the executable are owned by the user or by root
   (neither may be a symlink).
4. **Listed:** the bundle's `CFBundleIdentifier` (read from `<name>.app/Contents/Info.plist`) is in the guest's
   setting `dock.hosts`, compared exactly. The default list is empty: no host docks until the user lists one (for
   example `com.example.host`). `dock.hosts` is edited in the settings file only.

A connection that fails a check gets `{"t":"bye","why":"refused"}` (none when the uid differs) and is closed. The
guest's menu line names the reason; a connection from an unlisted app names its bundle id, so the user knows what to
add.

The **host** checks the guest the same way, on its connected socket, right after `connect` and before it sends its
`hello`:

1. `getpeereid` gives the host's own uid.
2. `LOCAL_PEERPID` gives the pid of the process that listens (the guest), and its start time can be read; the host
   records both for its `NOTE_EXIT` watch.
3. `proc_pidpath` of that pid is a regular file directly in `<name>.app/Contents/MacOS/`; the `.app` folder and the
   executable are owned by the user or root (neither a symlink, checked with `lstat`).
4. `CFBundleIdentifier` from `<name>.app/Contents/Info.plist` (a regular file, at most 1 MiB) is in the host's own
   list of guests, compared exactly (for Pitbox: `io.github.drcollect.pitbox`, or the id a self-built copy was signed
   with). The host must not use a LaunchServices lookup (`NSRunningApplication`) instead: it knows nothing of a
   bundle that was never registered (a fresh build) and can differ from the bundle on disk after a rename.

A guest that fails a check is closed without a word.

### 2.3 One host at a time, and docking off

The guest serves one host at a time. While a link exists, every further connection that passes the checks gets
`{"t":"busy"}` and is closed. In a rare race (the previous link was ending at that moment) `busy` may come right
after the guest's `hello`; a host treats `busy` the same way whenever it comes.

**Docking off.** While the user has docking turned off (the menu tick, setting `dock.enabled`), the guest has **no
socket**: it does not bind `dock.sock` at launch, and turning docking off while it runs sends
`{"t":"bye","why":"settings"}` to a connected host, closes the link and removes the socket (as at quit). A host's
connect then fails (`ENOENT` or `ECONNREFUSED`) and it keeps its normal backoff (section 2.4) while the guest's process
lives; a host that received `bye` with `settings` may show "docking is off in Pitbox" in its menu until a connection
succeeds. Turning docking on binds the socket again. (A guest that is bound but has docking off answers every
connection with `bye` `settings` and closes it; Pitbox does not keep a socket bound while off.)

### 2.4 Finding each other without polling

- The host watches the workspace's launch and quit notices for the guest's bundle id and connects when the guest
  launches. While the guest's process exists (kqueue `NOTE_EXIT` on its pid ends the watch), the host retries a failed
  or closed connection with backoff: 0.2, 0.5, 1, 2, 4, 8, 16, then every 30 s.
- **No stall at launch:** while the guest's process is younger than 10 s (its start time, `proc_pidinfo`), the host
  retries every 0.2 s whatever ended the last attempt (a failed connect, `busy`, `bye`, a handshake timeout, a
  violation); after that the backoff above resumes where it was.
- After `busy`, `bye` with `settings`, `refused` or `timeout`, a failed connect (no socket while docking is off,
  section 2.3), a handshake timeout of its own or a violation, the host keeps retrying with that backoff. After `bye` with `version` the host stops retrying until the guest's process
  changes (a new launch) or the host itself is updated. A host connected successfully resets its backoff to 0.2 s.
- The guest watches the same notices for the bundle ids in `dock.hosts` only to decide how long to wait before showing
  (section 8) and to notice a listed host app that runs without connecting (section 9).

## 3. Framing

### 3.1 Lines

- The link carries **lines**: one JSON object (RFC 8259) encoded as **UTF-8**, followed by one newline (`\n`, 0x0A). A
  carriage return right before the newline is allowed and dropped. A line holding only spaces or tabs is ignored (it
  still counts against the rate).
- A line holds **at most 16384 bytes** before its newline. A receiver treats a longer line as a violation as soon as
  it has seen 16385 bytes without a newline; it does not wait for the end of the line.
- **Rate:** each side sends **at most 50 lines a second**. A receiver keeps a bucket of 50 tokens, refilled at 50 a
  second up to 50; each line takes one token; a line that finds the bucket empty is a violation. A sender should pace
  itself well below that: Pitbox's guest uses a bucket of 25, refilled at 25 a second, and keeps only the newest unsent
  `area`, `attention`, `ping` and `pong`.

### 3.2 Strict JSON

- Exactly RFC 8259: no comments, no trailing commas, no single quotes, no `NaN` or infinities, no leading zeros, no
  unescaped control characters in strings, no lone surrogates in `\u` escapes, nothing after the value but whitespace.
  Numbers must be finite as IEEE doubles (`1e999` is invalid).
- **Nesting at most 8:** the line's own object counts as level 1; every object or array inside adds one.
- **A duplicated key** (in any object of the line, comparing the keys after their escapes are decoded) drops the whole
  line: neither value is used. The link stays. Every key of this protocol is ASCII; Pitbox also counts two Unicode keys
  that are canonically equivalent as the same key.
- Every line is an object with a string member `t`, the message type.
- Senders must write compact lines (no newline inside a line, which plain JSON encoders never produce) and should not
  escape non-ASCII text.

### 3.3 What a receiver does with a bad line

| Case | Effect |
| --- | --- |
| Line longer than 16384 bytes; more than the rate allows; not UTF-8; not JSON; nesting deeper than 8; not an object with a string `t` | **Violation** |
| Before the handshake: a first line that is not `hello`; a `hello` with a missing or ill-typed required field or the wrong `role` | **Violation** |
| After the handshake: a second `hello` | **Violation** |
| A duplicated key anywhere in the line | Line dropped, counted |
| After the handshake: a known message with a missing or ill-typed required field, or a value out of range | Line dropped, counted |
| An unknown `t` (after the handshake) | Ignored, counted |
| An unknown field, an unknown entry in a list of words, an unknown word in a field of words | Ignored, counted; an unknown word reads as that field's default |
| A message of a feature not in use (section 6) | Ignored, counted |

On a **violation** the receiver sends `{"t":"bye","why":"protocol"}` if the socket takes it at once, closes the link,
and logs one label naming the rule ("line too long", "rate", "malformed", "nesting", "not UTF-8", "not a message",
"hello expected", "bad hello", "second hello"). It never crashes and never acts on the line. Counts of ignored and
dropped lines go to the log when the link ends. Logs hold labels and numbers only, never the content of a line.

## 4. Handshake

- **Each side's first line is `hello`.** The guest sends its `hello` as soon as it accepted the connection (after its
  checks); the host sends its `hello` as soon as it connected and checked the guest. A side does not wait for the
  other's `hello` before sending its own.
- Each side must receive the other's `hello` **within 2 s**, counted on each side from its own start of the link:
  the guest from the moment it **accepted** the connection, the host from the moment it **sent its own `hello`**
  (right after its connect and its checks). A connection can wait in the guest's backlog before it is accepted (the
  connect itself succeeds at once); the guest accepts from the first moment of its launch, so this wait stays short.
  A side whose 2 s pass sends `{"t":"bye","why":"timeout"}` and closes; a host then retries as in section 2.4 (every
  0.2 s while the guest is younger than 10 s).
- **Version:** each `hello` carries `proto: [min, max]`, the protocol majors the sender speaks. Both sides use the
  highest major in both ranges: `min(max₁, max₂)` if it is at least `max(min₁, min₂)`. With no common major the side
  that sees it first sends `{"t":"bye","why":"version"}` and closes; neither side docks, and both menus show the
  version line of section 9 (for example "Can't dock with Pitbox: protocol 2, the host speaks 1").
- **Features:** each `hello` lists the optional parts it offers (section 6). A feature is used only when both lists
  name it; each side ignores and counts the messages of features not in use and does not send them.
- **The host's private state:** the host's `hello` may announce `wakeWords` (words the guest's spoken line must never
  say) and `private.folders` / `private.socketFolders` (its own private state). The guest uses them only after the
  host passed every check of section 2.2 and the handshake succeeded, and only the folders that pass the folder rule
  of section 5.3. The guest's command sandbox denies file access under every accepted folder and socket connects under
  every accepted socket folder, and **remembers them append-only** (they stay denied after the host quits and after
  the guest restarts), at most 64 per kind in all, across every host and reconnect (section 5.3).

## 5. Messages

### 5.1 Value types

| Type | Meaning |
| --- | --- |
| int | A JSON number with no fractional part, in the range the field names (default 0 to 10¹⁵ − 1) |
| number | A finite JSON number |
| bool | `true` or `false` |
| word | A string from the field's list; an unknown word reads as the field's default and is counted |
| text | A one-line string: no control characters (C0, DEL, C1), no line or paragraph separators, not blank, at most the bytes the field names |
| frame | An object `{"x": number, "y": number, "w": number, "h": number}` in **AppKit global points**: origin at the bottom left of the primary display, y up; `w` and `h` greater than 0; every value within ±10⁵ (`w`, `h` at most 10⁵) |

Fields marked *optional* may be missing; every other field is required.

### 5.2 Summary

| Direction | `t` | Fields | Feature |
| --- | --- | --- | --- |
| both | `hello` | `proto`, `minor`, `role`, `app`, `build`, `features`; host adds `wakeWords`, `private` | |
| guest → host | `busy` | none | |
| host → guest | `place` | `seq`, `displayID`, `displayUUID`, `edge`, `host`, `visible`, `level`, `live`, `cell`, `maxWidth` | |
| guest → host | `area` | `seq`, `frame`, `folded`, `visible` | |
| host → guest | `appearance` | `scheme`, `backdrop` | `appearance` |
| host → guest | `focus` | `key` | `focus` |
| host → guest | `fold` | `folded` | `fold` |
| guest → host | `claim` | `pid`, `windowNumber` | `guard.claims` |
| guest → host | `release` | `pid`, `windowNumber`, `parked` | `guard.claims` |
| guest → host | `mouseUp` | none | `guard.claims` |
| guest → host | `attention` | `needsYou`, `finished`, `running` | `attention` |
| guest → host | `speech.begin` | `id` | `speech` |
| host → guest | `speech.ok` | `id` | `speech` |
| host → guest | `speech.no` | `id`, `why` | `speech` |
| guest → host | `speech.end` | `id` | `speech` |
| both | `ping`, `pong` | none | |
| both | `bye` | `why` | |

A message sent in the wrong direction is an unknown type for its receiver.

### 5.3 `hello` (both directions, first line)

| Field | Type | Meaning |
| --- | --- | --- |
| `proto` | array of two ints `[min, max]`, 1 ≤ min ≤ max ≤ 9999 | The protocol majors the sender speaks. Version 1.0: `[1, 1]` |
| `minor` | int 0-9999, *optional* | The minor version of the sender's highest major (informational; for logs) |
| `role` | word `host` or `guest` | Must match the sender's side, or the `hello` is bad |
| `app` | text, ≤ 200 bytes | The sender's display name (the other side's menu shows one clean line of at most 40 characters) |
| `build` | text, ≤ 100 bytes | The sender's version |
| `features` | array of words, ≤ 64 entries | The features the sender offers (section 6) |
| `wakeWords` | array of text, ≤ 64 entries of ≤ 64 characters, *optional*, host only | Words the guest's spoken line never says |
| `private` | object, *optional*, host only | `folders` and `socketFolders`: arrays of text, ≤ 1024 bytes each, ≤ 16 entries each; specific app-private folders (the folder rule below) |

Invalid entries of the lists (and entries beyond a list's limit) are dropped and counted; a list that is not an array
makes the `hello` bad.

**The folder rule for `private`.** An announced folder must be a specific app-private folder. The guest takes its
canonical path: `realpath(3)` of the part that exists (links and `..` there resolved), the rest appended with `.`
dropped; an entry with a `..` after the part that exists, or that is not absolute (`~` is not expanded), is refused.
The canonical path must then lie

- at least **3 components below the user's home folder** (for example `~/Library/Application Support/<App>`), or
- at least **1 component below `/private/tmp`** (for example `/private/tmp/<app>-runner-<uid>`; `/tmp/...` is accepted
  in its canonical spelling `/private/tmp/...`),

and it is never `/`, the home folder or one of its ancestors, `/Users`, `/System`, `/Library`, `/Applications`,
`/private`, `/var`, `/tmp`, `/private/tmp`, `/private/var`, `/Volumes`, `/opt`, `/usr`, `/bin`, `/sbin`, `/etc`,
`/dev`, `~/Library` or `~/Library/Application Support`, also when a link or `..` leads there. Anything else (a
per-user temporary folder under `/private/var/folders`, a folder on another volume, or one or two components below
the home folder such as `~/Documents` or `~/Documents/Notes`) is refused too. Deeper folders under the home folder
pass the rule; a host should announce only its own private folders.

A refused entry is dropped (the rest of the `hello` stands), counted, and logged with a label only ("dock: announced
folders refused", with the count; never the path). It is never remembered and nothing is sent back. The guest passes
an accepted folder on in its canonical form, and its sandbox memory applies the same rule again: when it reads its
file (an entry an older build stored is dropped there) and whenever a command starts (an entry that has since become
a link to a broad folder is left out of the sandbox, not widened). **Caps:** at most 16 entries per list in one
`hello`; at most 64 distinct folders per kind remembered in all, across every host and reconnect; a new folder beyond
that is refused and logged ("dock: private folders capped"); a folder remembered before is never dropped to make
room.

```json
{"t":"hello","proto":[1,1],"minor":0,"role":"guest","app":"Pitbox","build":"1.0.0","features":["appearance","attention","focus","fold","guard.claims","speech"]}
{"t":"hello","proto":[1,1],"minor":0,"role":"host","app":"Host","build":"4.2","features":["appearance","focus","fold","guard.claims","speech"],"wakeWords":["hey host"],"private":{"folders":["/Users/alex/Library/Application Support/Host"],"socketFolders":["/private/tmp/host-runner-501"]}}
```

### 5.4 `busy` (guest → host)

No fields. Sent instead of `hello` to a host that connects while another host's link exists; the guest closes right
after it.

```json
{"t":"busy"}
```

### 5.5 `place` (host → guest)

Where the host's strip is. Sent once right after the handshake, then on every change of the host's frame, visibility,
display, edge or level, and again after the host's layout settles following a display sleep, wake or change. During a
live width drag at most 30 a second.

| Field | Type | Meaning |
| --- | --- | --- |
| `seq` | int | Increases with every `place`; `area` answers it |
| `displayID` | int 0 to 2³² − 1 | The host's display (`CGDirectDisplayID`) |
| `displayUUID` | text ≤ 64 bytes, *optional* | The host's display UUID |
| `edge` | word `left` or `right` (no default: another word drops the line) | The host's screen edge; the guest sits on the other side of the host (the window side) |
| `host` | frame | The host's strip |
| `visible` | bool | False while the host hides its strip: the guest hides too and comes back with it |
| `level` | word `above` (default) or `behind` | The host's window level: above normal windows (floating − 1) or behind them. The guest uses the same level and the same collection behaviour |
| `live` | bool, *optional* (default false) | A live width drag is in progress: the guest moves its panel with the host's edge but publishes its window-guard region only at the first `place` without `live`, or 1 s after the last `place` |
| `cell` | object | The host's grid in points: `width` (number > 0, required), `gutter` (≥ 0, default 12), `padding` (≥ 0, default 16), `row` (> 0, default 69); each ≤ 10000. The guest uses `width` for its columns; the other three are informational in 1.0 (the guest keeps its own 12 pt gutter and 16 pt padding) |
| `maxWidth` | number 0 to 10⁵ | The most width the guest may take, in points; the host computes it so that the whole docked area stays within its own limit |

```json
{"t":"place","seq":12,"displayID":1,"displayUUID":"37D8832A-2D66-02CA-B9F7-8F30A301B230","edge":"right","host":{"x":3533,"y":98,"w":1587,"h":1312},"visible":true,"level":"above","live":false,"cell":{"width":301.4,"gutter":12,"padding":16,"row":69},"maxWidth":800}
```

### 5.6 `area` (guest → host)

The rectangle the guest took, after it applied a layout; also on fold and unfold. Sent only while docked; the same
report for the same `place` goes out once.

| Field | Type | Meaning |
| --- | --- | --- |
| `seq` | int | The `place` this layout answers |
| `frame` | frame | The guest's panel |
| `folded` | bool | The 24 pt rail shows (folded by the user, or nothing wider fits) |
| `visible` | bool | The guest's panel is on screen |

```json
{"t":"area","seq":12,"frame":{"x":2902,"y":98,"w":631,"h":1312},"folded":false,"visible":true}
```

The host checks every `area` (section 7) and ignores one that fails.

### 5.7 `appearance` (host → guest, feature `appearance`)

The host's look, on change and once after the handshake. The guest follows it while docked and draws a 1 px seam on
the host's side; alone, or when the host leaves, it uses the system's look.

| Field | Type | Meaning |
| --- | --- | --- |
| `scheme` | word `system` (default), `light`, `dark` | Light or dark |
| `backdrop` | word `glass` (default), `vibrancy`, `solid` | The material behind the content |

```json
{"t":"appearance","scheme":"dark","backdrop":"glass"}
```

### 5.8 `focus` (host → guest, feature `focus`)

The host's focus, on change and once after the handshake.

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | text ≤ 64 bytes | `all`, or a focus name. The guest maps names through its own settings; an unknown name shows everything. When the host leaves, the guest goes back to `all` |

```json
{"t":"focus","key":"all"}
```

### 5.9 `fold` (host → guest, feature `fold`)

The host's menu item that folds or unfolds the guest.

| Field | Type | Meaning |
| --- | --- | --- |
| `folded` | bool | Fold (true) or unfold (false). This is the only setting the link may change |

```json
{"t":"fold","folded":true}
```

### 5.10 `claim`, `release`, `mouseUp` (guest → host, feature `guard.claims`)

While the user drags a window onto the guest to park it, the window usually still overlaps the host's strip, and the
host's window guard would slide it back while the guest is minimizing it. The guest mirrors each drop claim of its own
registry to the host:

| `t` | Fields | Meaning |
| --- | --- | --- |
| `claim` | `pid` (int 1 to 2³¹ − 1), `windowNumber` (int 0 to 2³² − 1) | "Leave this window alone for a moment", while the left button is down |
| `mouseUp` | none | The left button went up |
| `release` | `pid`, `windowNumber`, `parked` (bool) | The claim ended: parked (minimized), or not (look at the window again now) |

```json
{"t":"claim","pid":4242,"windowNumber":77}
{"t":"mouseUp"}
{"t":"release","pid":4242,"windowNumber":77,"parked":true}
```

The host checks every claim itself: the pid must belong to a running copy of the Claude desktop app (bundle id
`com.anthropic.claudefordesktop`) that the host knows itself, and the host's own claim registry bounds apply: a claim
holds at most 3 s after the mouse-up (the registry watches the button itself, so a lost `mouseUp` still ends it), at
most 30 s at all, at most 2 at once. A claim grants nothing but "leave this window alone for a moment". When the link
drops, the host's claims end within those bounds.

### 5.11 `attention` (guest → host, feature `attention`)

The guest's counts, on change, at most once a second (the newest counts win; unchanged counts are not sent again; the
current counts are sent once after the handshake). The host may show nothing.

| Field | Type | Meaning |
| --- | --- | --- |
| `needsYou` | int 0 to 10⁶ | Sessions waiting for the user |
| `finished` | int 0 to 10⁶ | Finished and unread |
| `running` | int 0 to 10⁶ | Running |

```json
{"t":"attention","needsYou":1,"finished":2,"running":3}
```

### 5.12 The speech pause (feature `speech`)

The guest speaks short phrases aloud; the host may run a microphone listener. The guest never speaks over it:

1. Guest → `{"t":"speech.begin","id":7}` before a phrase. `id` is an int, new for every request.
2. Host → `{"t":"speech.ok","id":7}` once its listener reports paused, or
   `{"t":"speech.no","id":7,"why":"talk"}` when a conversation (`talk`), dictation (`dictation`) or a locked screen
   (`locked`) holds the audio (`why` is a word with default `other`). A host that answers `no` undoes any pause it
   started for this request at once.
3. Guest → `{"t":"speech.end","id":7}` after the phrase. The host resumes its listener 0.5 s later, restoring the
   state it had before (never a plain "listen" that would start listening in the middle of a conversation).

Rules for the guest: one request at a time; no answer within **2 s** is `no` (nothing is said); a late `speech.ok` for
a request it gave up on is answered with `speech.end` at once; after every `ok` it sends `speech.end`, at the latest
60 s after the `ok`. Docked without the feature the guest says nothing aloud (the chime still plays). Alone (no listed
host app runs, or docking is off) it speaks directly. While a listed host app runs but is not docked, it says nothing
aloud.

Rules for the host: without a `speech.end`, it resumes its listener 15 s after the `speech.begin`, so the listener can
never stay paused. When the link drops, it resumes at once.

### 5.13 `ping`, `pong` (both)

No fields. Section 10.

```json
{"t":"ping"}
{"t":"pong"}
```

### 5.14 `bye` (both)

Sent before a normal close; the sender closes right after it. The receiver ends the link (it does not answer).

| `why` (word, default `other`) | When |
| --- | --- |
| `quit` | The app quits |
| `update` | The app is about to be replaced by a newer build |
| `settings` | The user turned docking off (the guest then removes its socket, section 2.3), or the peer is no longer in the allow list |
| `version` | No common protocol major (section 4) |
| `refused` | The peer failed the checks of section 2.2 (sent instead of `hello`) |
| `protocol` | The peer broke a rule of section 3 or 4 |
| `timeout` | The peer's `hello` did not come within 2 s |

```json
{"t":"bye","why":"quit"}
```

## 6. Features

| Name | Messages | Without it |
| --- | --- | --- |
| `guard.claims` | `claim`, `release`, `mouseUp` | The host's guard may slide a dropped window back while it still overlaps the host's strip |
| `appearance` | `appearance` | The guest uses the system's look while docked |
| `focus` | `focus` | The guest keeps its own focus |
| `speech` | `speech.begin`, `speech.ok`, `speech.no`, `speech.end` | Docked, the guest says nothing aloud |
| `fold` | `fold` | The host's menu cannot fold the guest |
| `attention` | `attention` | The host gets no counts |

`hello`, `busy`, `place`, `area`, `ping`, `pong` and `bye` are core: always in use.

## 7. Geometry and who draws what

- **Each app draws only its own windows.** No window of one app covers the other's on purpose. Both use the level of
  the latest `place` and the same collection behaviour, so they move together through Spaces and Mission Control.
- **The guest computes its own frame** from `place`: adjacent to `host` on the window side (the side opposite
  `edge`), on the host's display, with the host's exact top and bottom, its width from its own columns of the host's
  `cell.width` (two columns: twice `cell.width` plus Pitbox's 12 pt gutter and 16 pt padding on the window side; one
  column: `cell.width` plus 16 pt; folded: the 24 pt rail), at most `maxWidth` (a guest that would not fit drops to
  one column, then to the rail). It reports the frame in `area`.
- **The host checks every `area` against the `place` whose `seq` it answers** (not against its strip as it is now):
  adjacent to that `place`'s `host` frame on its window side, on the same display, the same top and bottom, width at
  most `maxWidth`, where coordinates within 1 pt count as equal. An `area` for an older `seq` than the host's latest
  `place` is ignored without a log (the guest's answer to the newer one follows). A frame that fails is ignored and
  logged with numbers only ("dock: area refused").
  The host then uses the **docked area** (its strip plus the checked `area`) wherever it means "the strip" for its own
  windows and layouts; it never moves its own strip because of the guest.
- **Window guards:** each app guards its own part. The guest's guard pushes windows toward its region's window side
  (by edge, never by the region's midpoint), so the two guards always push the same way and a window settles in at
  most two short hops. No pause or hand-off of a whole guard crosses the link; only drop claims do (section 5.10).
- Both apps must stay accessory apps (`LSUIElement`): each guard leaves non-regular apps' windows alone, so neither
  guard ever moves the other app's panel.
- **Fold order:** the guest shrinks its panel, then sends `area`, then publishes its guard region. **Unfold order:**
  it widens its panel, publishes its region, then sends `area`.

## 8. Start order

- **Guest:** with docking on, it binds `dock.sock` and accepts first thing at launch (section 2.1; off: no socket,
  section 2.3): a host that connects while the
  guest is still starting gets the guest's `hello` at once, and its `hello` and `place` wait in the guest until the
  guest's panel is ready. When the panel is ready, if a host is connected or an app listed in `dock.hosts` runs, the
  guest waits up to **1 s** for the host's first `place` before showing, so it does not jump from the screen edge to
  the host. Without a `place` by then it shows alone at the screen edge, and docks when the `place` comes. If no host
  is connected and no listed host app runs, it shows alone at once and docks whenever a host connects later.
- **Host:** at its launch, if the guest runs, it connects at once and retries every 0.2 s while the guest is younger
  than 10 s (section 2.4).
- **Host:** when a guest answers at launch, it waits up to **0.5 s** for the first `area` before showing its strip,
  so the two do not overlap at the edge.
- **Host hides its strip** (`place.visible: false`): the guest hides too and comes back with it. The guest's menu can
  still show it alone at the screen edge meanwhile; then it sends no `area` until the host shows its strip again.

## 9. Quit, crash, hang and version

| Event | Host | Guest |
| --- | --- | --- |
| Guest quits | Gets `bye` or end of file; drops the docked area at once (its own strip alone again) | (gone) |
| Guest crashes | End of file (and `NOTE_EXIT`), same as quit; reconnects at the next launch notice | (gone; the system removes its windows) |
| Guest hangs | No line for 15 s with a ping outstanding: keeps the last area while the guest's process exists (its frozen panel is still on screen) and shows "Pitbox not responding" in its menu | |
| Host quits or crashes | (gone) | End of file or `NOTE_EXIT`: alone within 1 s: moves to the screen edge, its guard keeps guarding its moved rectangle, the spoken line speaks directly |
| Host hangs | | No line for 15 s with a ping outstanding: stays docked while the host's process exists; the menu says "<host> not responding" |
| Host relaunches | Connects, handshake, `place`; waits up to 0.5 s for `area` before showing | Moves back beside the host, sends `area` |
| Display sleep, wake, change | Re-sends `place` after its layout settles | Follows; its guard holds corrections 3 s after a display change |
| No common major | No docking; menu: "Can't dock with Pitbox: protocol 2, <host> speaks 1" | Alone, with the line "Can't dock with <host>: Pitbox speaks protocol 1, <host> speaks 2" |
| A listed host app runs but does not connect within 5 s | (an old build without dock support) | Alone, with the warning "The host app is running without dock support: two apps may park the same windows. Update or quit one" |
| User turns docking off on the guest | Gets `bye` with `settings` (may show "docking is off in Pitbox"); its connects fail while the guest has no socket; keeps its normal backoff while the guest's process lives | Alone; no socket until docking is turned on again (section 2.3) |

## 10. Liveness

- **Process:** each side watches the other's pid with kqueue `NOTE_EXIT` (a dispatch process source) from the moment
  the link is accepted (the host: from the moment it connected). An exit ends the link at once, even while the socket
  is still open (for example held by a child process).
- **Socket:** end of file or a reset ends the link at once.
- **Ping:** a side that has received nothing for **5 s** sends `ping`, and again every 5 s while nothing arrives. A
  side answers every `ping` with `pong` (it may answer a burst of pings with one `pong`). Any line counts as traffic.
- **Not responding:** when a side's first unanswered `ping` is 10 s old (15 s without any line from the peer), the
  peer is **not responding**. This only changes the menu line: the link stays, and the docked area stays while the
  peer's process exists. The first line that arrives ends "not responding".
- After a sleep of the Mac (a check that fires more than 2 s after it was due), a side starts over: it sends a fresh
  `ping` and counts the 10 s from there, so a sleep never shows as a hang.

## 11. What the link can never do (normative)

This section is an invariant. An implementation of either side that breaks it does not implement this protocol.

1. **No session content.** No line carries titles, headlines, summaries, commands, paths, URLs, file names, hosts or
   folder names of any session. Lines carry counts, booleans, frames, display ids, window numbers, pids, protocol
   words, the two apps' names and versions and the host's focus name, plus the two exceptions of the handshake: the
   host's `wakeWords` (words to avoid saying) and the host's `private` folders (its own private state, so the guest's
   sandbox can keep commands out of it).
2. **No actions.** No message starts, types into or stops a command; opens the run sheet, the console, a URL, a file
   or an app; presses a button; parks or restores a window; changes a setting other than `folded`; or reads anything
   back. The guest's only effects of a host message are: its panel's geometry, level and visibility; its look; its
   focus key; the words its spoken line avoids; the folders its command sandbox denies; fold and unfold; and the
   answer to its own speech request.
3. **One action on the host side:** a drop claim (section 5.10) makes the host's guard leave one checked window alone
   for at most 3 s after the mouse-up and 30 s at all.
4. **No path from the link to what runs.** In Pitbox, the dock module imports nothing that runs, shows sessions, parks
   or writes settings; the guest's callbacks carry plain values only. A test (`LinkInvariantTests`) scans the module's
   sources and pins its public surface; it fails on any import of the console, sessions, shell or guard modules and on
   any reference to the run sheet, the console, the parker, an opener, process launching or the settings writer.
5. **Commands cannot reach the socket.** Pitbox's command sandbox denies its own folder (which holds `dock.sock`), so a
   command run from Pitbox can never connect to the socket and pose as a host.

Worst cases from a fake host (same user): the guest placed oddly within a display, folded, hidden (`visible: false`),
put behind windows (`level`), a docked area up to `maxWidth`, every spoken line refused, a wrong focus key, or up to
64 specific app-private folders per kind denied to the guest's commands (never `/`, the home folder, a system folder
or `~/Library`, section 5.3). The escape is the guest's menu: untick docking (the guest then runs alone, with no socket); a remembered
folder stays denied, by design (a host's private state must stay closed after the host quits).
From a fake guest: a docked area up to `maxWidth` that the host's layouts avoid, and one window left over the host's
strip for at most 30 s. Nothing that runs, reveals or deletes.

## 12. Versioning

- `proto: [min, max]` in `hello`; both sides use the highest common **major** (section 4).
- **Minor versions only add** optional fields, optional messages, words and features. Older peers ignore and count
  them (section 3.3). A minor version never changes the meaning or type of an existing field and never makes an
  optional field required.
- A change that an older peer cannot ignore is a new **major**. A side may speak several majors (`[1, 2]`) during a
  transition.
- A feature is used only when both sides list it in `features`.
- This document is the single source. The guest's implementation names the version in `DockProtocol` (`majors`,
  `minor`); a host names the version it implements in its own code and in `hello.build`.
- The protocol version is separate from either app's version and changes rarely.

## 13. Pitbox's implementation (informative)

- `DockListener` (bound by the app right after its single-instance lock while docking is on; the app's `DockWiring`
  stops it and removes the socket when docking is turned off), `DockSession` (one link: framing, strict
  parsing, handshake, liveness; one serial queue, dispatch sources on a non-blocking socket, no blocking call),
  `DockGuest` (main actor: the state `alone`, `waitingForHost`, `docked`, `hostNotResponding`, `refused`, the
  callbacks and the senders), `StrictJSON` and `DockWire` (the reader and the message types).
- Tests on fakes: `Tests/PitboxDockTests` (malformed and oversized lines, a rate flood, nesting, duplicate keys,
  unknown fields and types, version mismatch, a second host, a stale socket, a late host, `kill -9` of the host
  process, a hung host, `place.live`, `speech.no` and a missing `speech.ok`, the handshake timeout, the peer checks,
  and the link invariant).
