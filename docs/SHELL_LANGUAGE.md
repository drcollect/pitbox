# The shell language the command reader accepts

Pitbox offers the shell commands a Claude Code session hands you, and its command reader (`PitboxKit`'s
`ShellCommandScanner` and `CommandClassifier`) decides what the run sheet says about each one. This document is the
language that reader accepts, written out as a precise contract, together with the readings the independent test
vectors assume where the rules leave room. The vectors live in `Tests/PitboxKitTests/ShellVectors.swift` and run
through `CommandClassifier.assess(text:context:)` in `Tests/PitboxKitTests/ShellVectorTests.swift`. They were written
independently of the scanner and classifier and are the yardstick the implementation must meet; while
`CommandClassifier.policyVersion == 0` (a fail-closed placeholder; the shipped value is 1) the test returns early.

Nothing in this document makes a command safe. The reader recognises shapes; it cannot tell what a program will do.
What the run sheet does with the result is in [THREAT_MODEL.md](THREAT_MODEL.md).

Terms: the **text** is the exact bytes an offer would run (the command lines of one block, joined by `\n`). A **word**
is one shell word after the scanner has kept its quoting apart from its characters (`"r""m"` is one word with the
characters `rm`). A **segment** is one command (§3.1). The **program** is the base name of a segment's command word
after wrappers and assignments were looked through. An **operand** is a word that is not an option. A § number with a subsection
from §8.1 on, or from §9 on (such as §8.6 or §9.1), names a rule of the command-offer design this contract was first
written from; the headings keep those numbers so their links stay stable, and each rule is stated here in full.
The rule ids R1-R22 and B1-B6 are the ones the run sheet shows; §5 has an example of each.

## 1. Order of reading

1. **Characters (B1)** on the raw text, before anything is tokenised. A B1 character anywhere, also inside quotes,
   comments and here-doc bodies, blocks the whole offer. Nothing further is trusted, though the scanner may still
   report what else it saw.
2. **Size (B4)**: more than 40 lines, more than 4,000 characters (newlines counted, Unicode scalars, not bytes), a line
   longer than 500 characters, or more than 2,000 tokens (a scanner limit, §11.2). The checks run before parsing, so a
   pathological text costs nothing. A text at exactly a limit (40 lines, 4,000 characters, 500 per line) is accepted.
3. **Tokens and words**: quoting, escapes, operators, redirections, comments, backslash-newline joins.
4. **Spelling (B2)**: non-ASCII in a program name, an option, a host or a user name.
5. **Structure (B3)**: the accepted grammar; anything else, and anything unbalanced or unterminated, is "cannot
   read". The scanner never guesses.
6. **Segments and machines** (§4.1), then **patterns** (R1-R21, B5, B6) on each segment, nested scripts included.
7. **The class** (§4 below). The worst segment decides; flags point at their segment.

A text can carry several block reasons; `CommandAssessment.blockReason` is the first flag in text order. The vectors
only require that the named reason is among the flags.

## 2. The accepted language

| Construct | Example | Notes |
| --- | --- | --- |
| simple command | `ls -la ~/x` | words, options, operands |
| assignments before a command | `FOO=1 BAR=2 cmd` | looked through (§3.2); a line of only assignments is a segment with no program |
| pipeline | `a \| b \| c` | each stage is a segment |
| lists | `a; b && c \|\| d & e`, newlines | `;`, `&&`, `\|\|`, `&` and the newline split segments; a trailing `&` is R8 |
| groups | `( a; b )`, `{ a; b; }` | the inner commands are segments |
| `if`/`then`/`elif`/`else`/`fi` | `if [ -f x ]; then a; else b; fi` | every command in the condition and the branches is a segment |
| `for`/`in`/`do`/`done` | `for f in *.md; do echo "$f"; done` | the body's commands are segments; the glob is noted |
| `while`, `until` | `while read -r l; do echo "$l"; done < x` | as `for` |
| `case`/`esac` | `case $x in a) b;; *) c;; esac` | the clause commands are segments |
| `[[ … ]]`, `(( … ))` | `[[ -n $x ]] && a`, `(( n > 1 ))` | conditions, no program |
| single quotes | `'a; b'` | one word, nothing inside is an operator, a comment or an expansion |
| double quotes | `"a $X $(b)"` | one word; `$X` and `$(b)` inside are read |
| `$'…'` | `$'a\tb'` | one word with C escapes; `$'\x..'` building a command word is R11 |
| backslash escapes | `a\ b`, `\$x`, `\rm` | the escaped character is text; `\rm` is the program `rm` |
| backslash-newline | `cmd \` + newline + `  arg` | joined before anything else, inside and outside quotes |
| parameters | `$NAME`, `${NAME}`, `${NAME:-word}`, `${NAME:=word}`, `${NAME:?word}`, `${#NAME}`, `$1`-`$9`, `$?`, `$$`, `$@` | `word` may hold text and `$(…)`; a second `${…}` inside is B3 (nested) |
| command substitution | `$(a)`, `` `a` `` | a nested script: its segments carry flags; also inside double quotes; at most 8 levels deep |
| arithmetic | `$((1 + 2))` | a `$(…)` inside it is read as a nested script |
| process substitution | `<(a)`, `>(a)` | nested scripts; `>(sh)` fed by a pipe counts as piping into `sh` |
| redirections | `<`, `>`, `>>`, `>\|`, `2>`, `2>&1`, `&>`, `<<`, `<<-`, `<<<` | a numbered descriptor before the operator (`2>`) belongs to it |
| here-docs | `cat <<'EOF'` … `EOF`, `cat <<-EOF` (tabs stripped) | the body ends at a line that is exactly the delimiter (no trailing spaces); two here-docs on one line take their bodies in order |
| here-strings | `wc -c <<< "x"` | the word is read like any word |
| tilde, globs, braces | `~`, `~/x`, `*.md`, `?`, `[ab]`, `**/`, `{a,b}` | noted ("expanded when it runs"), never expanded by Pitbox |
| comments | `# full line`, `cmd # trailing` | `#` starts a comment at the start of a word, outside quotes; the comment runs to the end of the line and swallows any `;` after it; `a#b` is one word |

### 2.1 Not accepted (B3, "Pitbox can't read this shell syntax; use Copy")

- unbalanced or unterminated text: a quote, a `$(`, a backtick, a `(`, a `{`, a `[[`, a `((`, a here-doc whose
  delimiter line never comes (also when it comes with a trailing space), a final `\`, an `if`/`for`/`while`/`case`
  without its closing word;
- zsh parameter flags and modifiers: `${(e)x}`, `${~x}`, `${=x}`, `${^x}`, `${!x}`, `${x:h}`, `${x:t}`, `${x//a/b}`,
  `${x#p}`, `${x%s}` and every other form not in the table above; nested `${…${…}}`;
- glob qualifiers `*(.)`, `*(e:…:)`; `=cmd` and `=(…)`; history words `!!`, `!rm`, `!$`;
- the words `alias`, `unalias`, `functions`, `setopt`, `unsetopt`, `emulate`, `autoload`, `zmodload`, `trap`,
  `coproc`, `select`, `repeat`, `always`, `noglob` in command position, and function definitions (`f() { …; }`,
  `function f { … }`);
- more than 8 levels of nesting (substitutions and process substitutions counted together);
- a wrapper option the scanner does not know (§3.2), so the program cannot be found.

B3 is a block even when the readable part is harmless. The vectors never require a red line for B3 texts: an
implementation may stop at the first thing it cannot read.

## 3. Segments, wrappers and the program

### 3.1 How segments split
- `;`, `&&`, `||`, `|`, `&` and the newline end a segment, outside quotes and outside `$(…)`, backticks, `<(…)`,
  `>(…)` and here-doc bodies. `|&` is `2>&1 |`. A `;;` ends a `case` clause.
- Compound commands (`if`, `for`, `while`, `until`, `case`, `( … )`, `{ … }`) are not segments themselves; the
  commands inside them are. Their keywords are never programs.
- A nested script (a substitution, the words after an `ssh` host, a here-doc or pipe body that reaches a shell) is
  split the same way. Its flags are attached to the enclosing top-level segment, with the nested words underlined.
  `CommandAssessment.segments` lists the top-level segments only; the vectors check programs only for plain texts.
- A segment of only assignments (`DIR=build`) or only a redirection (`> x`) has `program == nil`.
- A comment is not a segment. A line that is only a comment counts as a line, not as a command.

### 3.2 Wrappers and assignments are looked through
Leading `NAME=value` words are skipped (their values are read for substitutions and for B6's "set to a literal
earlier in the same block"). Then these wrappers are skipped, with their options, until the first word that is neither
an option nor an assignment: `sudo`, `doas`, `env`, `command`, `builtin`, `exec`, `nohup`, `time`, `nice`, `xargs`,
`caffeinate`, `watch`, `setsid`. The wrapper itself still matches its own rule (`sudo` is R1, `xargs` and `nohup`
have theirs). Options that take a value must be skipped together with it, otherwise the value is read as the program
and a dangerous command looks harmless:

| Wrapper | Options with a value | Flags without a value (examples) |
| --- | --- | --- |
| `sudo` | `-u -g -h -p -C -D -R -T -U --user --group --prompt --chdir --host` (`-u x` and `-ux`, `--user=x`) | `-E -H -i -k -K -n -s -S -b -v` |
| `env` | `-u -C -S --unset --chdir --split-string` | `-i -0 -v` |
| `nice` | `-n --adjustment` | `-5` style numbers |
| `xargs` | `-I -J -L -n -P -R -s -E -d -a` (`-I{}` attached too) | `-0 -t -p -r -o` |
| `caffeinate` | `-t -w` | `-d -i -m -s -u` |
| `watch` | `-n -d --interval` | `-t -b -e -c -g -x` |
| `command` | none | `-p -v -V` (`-v`/`-V` only print: no program is run; the segment has `program == nil`) |
| `time`, `nohup`, `builtin`, `exec`, `doas`, `setsid` | `exec -a name`, `doas -u user` | `time -p`, `exec -c -l`, `doas -n -s` |

A wrapper option outside these tables is B3 (the program cannot be found without guessing). `sudo -u x rm -rf build`
therefore has the program `rm` and both R1 and R2; `nice -n 10 rm -rf build` has R2, never the program `10`.

### 3.3 Finding the program name
- The program is the command word's characters with quoting and backslashes removed, then its base name: `/bin/rm`,
  `\rm`, `"rm"`, `'r'm`, `"r""m"` and `r\m` are all `rm`.
- Compared **case-insensitively**: this Mac's volumes are case-insensitive, so `RM -rf ~` runs `/bin/rm` (on a default
  volume `/bin/RM` resolves). `Sudo`, `cURL` and `Open` match their rules.
- A command word that contains a variable or a substitution (`$cmd`, `"$(which rm)"`, `rm${IFS}-rf`) is R11; no
  further pattern is required for it (the program is not known).
- A command word given by a path outside the system folders is R18 (`./x`, `bin/x`, `~/tools/x`,
  `/Users/alex/my project/scripts/test.sh`, `"$HOME/bin/x"`). The system folders are the folders of the clean PATH
  (`/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`) and
  `/usr/libexec`; a program under `/System` or `/Library/Apple` is also a system program.
- Short options are split (`-rf` = `-r -f`, `-rfv` too); `--` ends options for the programs that honour it.
- Patterns match the program and the words of that segment only. `echo sudo`, `echo "rm -rf ~"` and `grep -rf p f`
  match nothing: the program is `echo` or `grep`.

### 3.4 B1: the character policy (version 1, built from the Unicode data of the Mac it runs on)
Blocked anywhere in the text, inside quotes too:
- every character of general category Cc or Cf except U+0009 (tab) and U+000A (newline). This includes U+000D
  (carriage return: the session side unifies line endings, so one left in the text is a signal), ESC, DEL, the C1
  range U+0080-U+009F, soft hyphen U+00AD, the bidi marks and overrides U+061C, U+200E, U+200F, U+202A-U+202E,
  U+2066-U+2069, the zero-width characters U+200B-U+200D, U+2060-U+2064, U+FEFF, and the tag characters
  U+E0001, U+E0020-U+E007F;
- every Default_Ignorable_Code_Point, adding U+034F, U+115F, U+1160, U+17B4, U+17B5, U+180B-U+180F, U+3164,
  U+FE00-U+FE0F (variation selectors), U+FFA0, U+E0100-U+E01EF;
- U+2028 and U+2029;
- every space other than U+0020: U+00A0, U+1680, U+2000-U+200A, U+202F, U+205F, U+3000.

Allowed, and noted with its code point: every other non-ASCII character inside a quoted word or an operand
(`echo "café"`, `mkdir "Übersicht"`, `echo "日本語"`, an emoji without a variation selector). The vectors assert
this only for quoted words; §6 lists the unquoted case as open.

### 3.5 B2: look-alikes in program, option, host and user
A non-ASCII character in the program word (`сurl` with Cyrillic с, fullwidth `ｒｍ`), in an option (a word in option
position beginning with a dash look-alike such as U+2010-U+2015, U+2212, U+FE63, U+FF0D, or any non-ASCII inside a
`-…` word), in a host (`ssh buildbоx`, `scp buildbоx:x …`, a URL host) or in a user name (`аlex@buildbox`) is
B2, Copy off. B2 is decided before the host is compared with the session's server, so a Cyrillic `buildbоx` is
never Fetch file and never R17; it is blocked.

## 4. Machines, Fetch file and the class

### 4.1 Machine (§8.6), as the vectors read it
- **Rule 1** (`ssh`, `mosh`, `autossh`, `et`): anything after the host word, standard input from `<`, a here-doc or a
  pipe, or `-o RemoteCommand=…` → `.remote(host:)` for every session place, the unknown place included. The host
  of `.remote` is the host word without a `user@` part (`ssh alex@buildbox uptime` → `buildbox`). Options that
  take a value (`-p -i -l -o -L -R -D -J -F -E -b -c -m -O -Q -S -W -w -B -e -I`) are skipped with it, so
  `ssh -p 2222 buildbox` and `ssh -L 8080:localhost:80 buildbox` have no command and are Mac commands.
  `ssh <alias>` alone is for this Mac in local and in SSH sessions ("opens a shell on buildbox").
  The remote words are scanned as a nested script; a quoted command is unquoted once (`'rm -rf /srv/x'`).
- **Rule 2** (`scp`, `rsync`, `sftp`, `sshfs`, `rclone`): a `[user@]host:path` operand naming the session's server (its
  alias, its resolved HostName or a `serverNames` entry, case-insensitively) makes the offer for this Mac; the remote
  path is never a path hint.
- **Rule 3**: the Mac-only and Linux-only program lists (`CommandPatterns`), matched on the program after wrappers.
- **Rule 4**: Mac paths and server paths as listed; only local operands, redirect targets and `cd` targets count.
- **Local session**: rule 1, else this Mac (also for `systemctl`, `/srv/x` and other server pointers).
- **SSH session**: rule 2 or a Mac-only program → this Mac; with a server pointer as well → unclear; server pointers
  only → server; path hints only (Mac or server paths, the session's own remote cwd) → unclear; nothing → unclear.
- **Unknown place**: unclear for everything except rule 1.
- **Claims**: a caption or a comment containing "on your Mac" or "on the server" (also "on this Mac", "locally",
  "on buildbox") is `replyClaim`. A claim that contradicts the result makes it unclear; one that agrees, or one
  that is the only hint, changes nothing (an SSH session's `ls` with the caption "on your Mac" stays unclear).

### 4.2 Fetch file (§9.1), as the vectors read it
Only from an SSH session with an alias. One segment, no chain, pipe, redirect, `&`, assignment, substitution,
variable or glob anywhere. `scp` options only from `-p -q -C -v` (combined `-Cq` allowed; `-P`, `-r`, `-o`, `-i`
refuse); `rsync` options only from `-a -v -z -h -t -P --progress --partial`. Exactly one `[user@]host:path` source
whose host is the session's server and whose path has no `..` part, no trailing `/`, none of `* ? [ ] { } $` or a
backtick after unquoting, at most 1,024 characters; `user` matches `^[a-z_][a-z0-9_-]{0,31}$` (so `Root@` refuses).
Exactly one destination among `~/Downloads`, `~/Downloads/`, `$HOME/Downloads`, `$HOME/Downloads/`,
`/Users/<user>/Downloads`, `/Users/<user>/Downloads/`, each optionally followed by one file name without `/`
(`~/Downloads/sub/` and `~/Downloads/../x` refuse). `FetchFileRequest.alias` is always the session's alias, also when
the reply wrote the HostName; `remotePath` is the path as unquoted; `destinationName` is the file name or nil.
Everything else is an ordinary command: a transfer naming the server is for this Mac (§4.1 rule 2), one naming
another host falls to the path rules (`scp devbox:x ~/Downloads/` is unclear in an SSH session).

### 4.3 The class
`partlyRead` is never returned by the classifier: the offer's `replyReadCompletely` is applied by the sheet. Among the
rest, the most restrictive wins, and every flag found is still listed:

1. `blocked` (any B1-B6),
2. `otherMachine` (rule 1), then `forServer`, then `needsEditing`, then `unclearMachine`,
3. `fetchFile` (the shape; a red line that can come from the text, R20, stays a flag with its tick on the Fetch sheet),
4. `risky` (any R1-R21), then `notFlagged`.

So `rm -rf build` in an SSH session is `unclearMachine` with R2 among its flags; `rm -rf <dir>` in a local session is
`needsEditing` with R2; `ssh buildbox 'cat x' \| sh` is `otherMachine` with R3.

## 5. Red lines and block reasons: minimal examples

| Rule | Matches | Does not match |
| --- | --- | --- |
| R1 | `sudo ls`, `sudo -u x rm -rf build` (with R2), `su - admin`, `doas ls`, `pkexec ls`, `osascript -e '… with administrator privileges'` | `sudoku`, `echo sudo` |
| R2 | `rm -rf build`, `rm -f notes.txt`, `rm *.log`, `rm "$FILE"`, `find . -name '*.o' -delete`, `git clean -fdx`, `git reset --hard`, `git checkout -- .`, `git restore .`, `git stash drop`, `git branch -D x`, `shred -u x`, `srm x` | `rm -i a`, `rm a.txt`, `rmdir d`, `git clean -n`, `git reset --soft HEAD~1`, `git stash`, `git branch -d x`, `grep -rf p f` |
| R3 | `curl -fsSL URL \| sh`, `curl URL \| sudo bash`, `wget -qO- URL \| sh`, `curl URL \| python3`, `sh -c "$(curl URL)"`, `bash <(curl URL)`, `source <(curl URL)`, `eval "$(curl URL)"`, `ssh buildbox 'cat x.sh' \| sh`, `pbpaste \| sh`, download + `chmod +x` + run in one block, `curl URL \| tee >(sh)` | `curl URL -o x.sh`, `curl URL \| jq .`, `curl -O URL` |
| R4 | `chmod -R 755 d`, `chmod 777 x`, `chmod a+w x`, `chmod o+w x`, `chmod u+s x`, `chmod 4755 x`, `chown root /usr/local/bin/x`, `chmod 644 /etc/hosts`, `chmod 755 /Users/other/x`, `xattr -d com.apple.quarantine x`, `xattr -c x`, `xattr -cr x`, `spctl --master-disable`, `spctl --add x` | `chmod 644 ~/Downloads/x`, `chmod +x build.sh`, `chmod 755 /Users/alex/x`, `xattr -l x`, `spctl --status` |
| R5 | `echo x >> ~/.zshrc` (also `"$HOME/.zshrc"`, `/Users/alex/.zshrc`), `cat > ~/.zshrc <<'EOF'`, `cat <<'EOF' > ~/.zshrc`, `echo x \| tee -a ~/.bashrc`, `cp c ~/.ssh/config`, `mv x ~/.gitconfig`, `ln -s x ~/.config/y`, `sed -i '' s/a/b/ ~/.zshrc`, `git config --global user.name x`, `crontab -l` (any crontab), `cp x.plist ~/Library/LaunchAgents/`, `echo x > ~/.claude/settings.json`, `rsync -a d/ ~/.config/`, a write under `~/Library/Application Support/Pitbox/` | `echo x > ~/notes.txt`, `cat ~/.zshrc`, `cp ~/.zshrc ~/zshrc.bak`, `git config user.email x` |
| R6 | `git push -f`, `--force`, `--force-with-lease`, `--mirror`, `--all`, `--delete x`, `-d x`, `+main`, `:feature`; `git filter-branch`, `git filter-repo`, `git reflog expire`, `git gc --prune=now`, `git update-ref -d` | `git push`, `git push origin main`, `git push -u origin x`, `git push origin HEAD:main`, `git gc`, `git fetch --all` |
| R7 | `security delete-generic-password -s N`, `dump-keychain`, `export`, `set-key-partition-list`, `unlock-keychain`, `add-trusted-cert`, `authorizationdb`, `create-keychain`, `default-keychain`, `set-keychain-settings`; `security find-generic-password -s N -w` alone, `… -g`, `… -w \| pbcopy`, `… -w > f`, `… -w` inside another command's arguments; `gh auth token`, `gh auth logout`; `cat ~/.ssh/id_ed25519`; `ssh-add -D` | `security add-generic-password -U -a "$USER" -s N -w` (note), `N="$(security find-generic-password -s N -w)" cmd` (note), `export N="$(security … -w)"` (note), `security find-generic-password -s N` (no `-w`/`-g`), `gh auth status`, `ssh-add -l` |
| R8 | `launchctl …` (any), `brew services start x`, `sfltool …`, `nohup cmd &`, `cmd &`, `disown`, `setsid cmd`, `screen -dm cmd`, `tmux new -d`, login items via `osascript` | `brew services list`, `a && b`, `echo "a & b"` |
| R9 | `defaults write\|delete\|import\|rename`, `PlistBuddy -c "Set …"`, `plutil -replace\|-insert\|-remove`, `pmset -a …`, `networksetup …`, `scutil --set`, `nvram …`, `csrutil …`, `tccutil …`, `dscl …`, `sysadminctl …`, `fdesetup …`, `profiles …`, `kextload …`, `systemextensionsctl …`, `softwareupdate --install` | `defaults read x`, `plutil -lint x`, `scutil --get HostName`, `softwareupdate -l` |
| R10 | `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`, `ssh-keygen -R host`, `ssh-copy-id buildbox`, `>> ~/.ssh/authorized_keys`, `>> ~/.ssh/known_hosts`, `cp c ~/.ssh/config`, `-o StrictHostKeyChecking=no`, `-o UserKnownHostsFile=/dev/null` | `ssh buildbox`, `ssh -o ServerAliveInterval=60 buildbox`, `ssh-keygen -l -f key.pub` |
| R11 | `eval …`, `base64 -d\|-D\|--decode`, `xxd -r`, `openssl enc -d`, `openssl base64 -d`, `uudecode`, `printf '\x..'` / `echo -e '\x..'` / `$'\x..'` as a command word, `${IFS}` in a word, `$cmd …`, `"$(which rm)" …` | `echo eval`, `base64 x > y`, `xxd x`, `openssl rand -hex 16` |
| R12 | `curl -T f URL`, `--upload-file`, `-F name=@f`, `-F 'd=<f'`, `-d @f`, `--data-binary @f`; `wget --post-file=f`; `scp f buildbox:/tmp/`, `rsync -a d/ buildbox:/srv/`; `rclone copy ./x r:b`; `aws s3 cp f s3://b/`; `gsutil cp f gs://b/`; `gh gist create f`; `gh release upload v1 f`; `nc host 9999 < f`; `pbpaste \| curl -d @- URL`; a network program using a variable filled from the Keychain earlier in the block | `curl -d 'a=b' URL`, `scp buildbox:x ~/Downloads/`, `rsync -a buildbox:/srv/x/ ./x/`, `rclone copy r:b ./x`, `aws s3 cp s3://b/x .` |
| R13 | `kill 1234`, `kill -9 1234`, `killall Dock`, `pkill -f node`, `launchctl kill …`, `shutdown -h now`, `reboot`, `halt`, `osascript -e 'tell application "Safari" to quit'` | `echo kill`, `ps aux \| grep node` |
| R14 | `diskutil …` (any), `dd …`, `mkfs.ext4 …`, `newfs_hfs …`, `fdisk …`, `gpt show disk0`, `asr …`, `hdiutil …` (any), `tmutil delete\|disable\|deletelocalsnapshots`, `bless …`, `umount -f …` | `tmutil listbackups`, `df -h` |
| R15 | `export X_API_KEY=sk-…` (20+ characters after `sk-`), `ghp_…`, `gho_…`, `github_pat_…`, `xox[abpr]-…`, `AKIA…`, `-----BEGIN … PRIVATE KEY-----`, a JWT, `Authorization: Bearer <40+ characters>`, `export *_KEY=literal`, `*_TOKEN=literal`, `*_SECRET=literal`, `PASSWORD=literal` | `export T="$(security … -w)"`, `export T="$T"`, `echo $OPENAI_API_KEY`, `pip install sk-dist`, `Authorization: Bearer $TOKEN` |
| R16 | `installer -pkg x -target /`, `open x.pkg`, `open x.dmg`, `open /Applications/X.app` (with R18), `brew install --cask x`, `npm install -g x`, `pip install --user x`, `pip install --break-system-packages x`, `gem install x`, `cargo install x`, `go install x@latest` | `brew install jq` (note), `pip install requests` (R18 only), `npm install` (R18 only) |
| R17 | `ssh bui1dbox`, `buildbx`, `buildb0x`, `buildbox2`, `biuldbox` (within two edits of a known host); `xn--…` hosts; a bare IP address that is not the session's server (`curl http://` followed by a numeric address, `ssh` to a private address) | `ssh buildbox`, `ssh alex@buildbox`, `ssh box.example.net` (the HostName), `ssh devbox`, `curl https://api.acme.test/` |
| R18 | `make …`, `npm run\|test\|start\|exec\|install\|i\|ci\|x`, `npx …`, `pnpm install`, `yarn`, `bun run x`, `pip\|pip3 install x`, `uv run\|sync\|pip install`, `poetry install\|run`, `bundle install\|exec`, `swift build\|test\|run`, `xcodebuild`, `cargo build\|run\|test`, `go run\|test\|build\|generate`, `gradle`, `./gradlew`, `mvn`, `docker build\|run\|compose`; `python x.py`, `node x.js`, `bash x.sh`, `sh x`, `zsh x`, `ruby x.rb`, `perl x.pl`, `osascript f`; `./x`, `bin/x`, `~/t/x`, `scripts/test.sh`; `source f`, `. f`; `python -c`, `perl -e`, `node -e`, `ruby -e`, `osascript -e`, `php -r`, `sh -c`, `bash -c`, `zsh -c`; `find … -exec\|-execdir\|-ok\|-okdir`; `xargs …` (any); `open -a X`, `open x.command\|.terminal\|.workflow\|.app`; `git -c k=v …`, `git config core.hooksPath\|core.fsmonitor\|core.sshCommand\|alias.*`; `direnv allow`; a shell fed a here-doc, a here-string or a pipe body | `open ~/Downloads/x.pdf`, `open https://acme.test/`, `python3 --version`, `node --version`, `swift --version`, `cargo --version`, `docker ps`, `npm ls`, `go version`, `git status`, `/bin/ls`, `/usr/bin/log show` |
| R19 | `osascript …` (any), `shortcuts run "X"`, `automator x.workflow`, `cliclick c:1,1` | `shortcuts list`, `echo osascript` |
| R20 | any text when `turnOrigin` is `taskNotification` or `peer` | `human`; `unknown` by the letter of the rule (see §6 A15 and §8 below) |
| R21 | decided by the sheet with `lstat`; the pure classifier reports write targets as notes (see §6) | a text with no write or copy target |
| R22 | never from the classifier: the session side and the sheet add it from `CommandOffer.supersession` (the session moved on since the reply); every vector fails if the classifier emits it | every text |
| B1 | any character of §3.4, also inside quotes: `ls<U+200B> -la`, `echo "a<U+200B>b"`, `rm<U+00A0>-rf build`, `<U+FEFF>ls`, `echo <U+202E>abc`, `echo a<U+000D>` | tab between words; `echo "café"`; an emoji without U+FE0F |
| B2 | `сurl …` (Cyrillic с), `ｒｍ …`, `ls <U+2011>la`, `rm <U+FF0D>rf x`, `ssh buildbоx`, `scp buildbоx:x ~/Downloads/`, `ssh аlex@buildbox` | `echo "сurl"` (quoted operand, noted) |
| B3 | §2.1: `echo "abc`, `echo $(ls`, `(ls`, `{ ls;`, an unterminated here-doc, `ls \`, `${(e)x}`, `${~x}`, `${x:h}`, `ls *(.)`, `=ls`, `=(ls)`, `!!`, `alias x=y`, `setopt x`, `f() { ls; }`, `trap 'ls' EXIT`, `repeat 3 ls`, `noglob ls *`, 9 nested `$(…)`, 200 unclosed `$(` | every row of §2 |
| B4 | 41 lines, 4,001 characters, a 501-character line, more than 2,000 tokens (B3 or B4) | 40 lines, 4,000 characters, a 500-character line |
| B5 | `echo … \| base64 -d \| sh`, `base64 -d f \| bash`, `… \| base64 --decode \| zsh`, `eval "$(… \| base64 -d)"`, `xxd -r -p f \| sh`, `openssl enc -d … \| bash`, `bash <(base64 -d f)`, `echo -e '\x..' \| sh` | `echo … \| base64 -d` (R11), `base64 -d f > g` (R11) |
| B6 | `rm -rf` (any spelling of §3.3, any wrapper, any position in a chain, group, loop, substitution, here-doc script) of `/`, `/*`, `~`, `~/`, `$HOME`, `"$HOME"`, `"${HOME}"`, `$HOME/`, `/Users`, `/Users/alex`, `..`, `*`, `"$DIR"`, `"$DIR/"`, `"$(pwd)"`, a variable set from a substitution or another variable; `dd` with `of=/dev/disk*` or `/dev/rdisk*` in any operand order; `> /dev/disk*`; `diskutil eraseDisk\|eraseVolume\|partitionDisk` on `disk0`, `disk0s*` or `/`; `chmod -R 000 /` | `rm -rf build`, `rm -rf ~/x`, `rm -rf /tmp/x`, `rm -rf /Users/alex/x`, `rm -rf "$DIR"/build`, `DIR=build` then `rm -rf "$DIR"`, `dd if=/dev/zero of=./f`, `chmod -R 000 /tmp/x`, `echo rm -rf ~` |

## 6. Where the spec is open, and the reading the vectors assume

| # | Open point | Reading assumed by the vectors |
| --- | --- | --- |
| A1 | The rules give no order among the classes when several apply | §4.3: blocked, then the machine classes and needsEditing, then fetchFile, risky, notFlagged; every flag is still listed |
| A2 | The host value of `.remote(host:)` for `user@host` | the host without `user@` (`buildbox`), so "Open a terminal on buildbox" can match the alias |
| A3 | `ssh buildbox` alone from an SSH session: §4.1 rule 1 says "a Mac command", the SSH-session rules would say unclear | this Mac, in local and SSH sessions |
| A4 | An unknown-place session with an `ssh host cmd` text | `.remote`, like every other place (nothing for another machine runs either way); not asserted |
| A5 | R21 needs `lstat`, but `CommandContext` carries no file facts | the pure classifier never emits R21 and reports write targets as "Writes <path>" notes; the sheet, which re-classifies with file access, turns existing targets into R21. The vectors never require or forbid R21 on a text with a write target. Contract request: a `CommandContext` field with the paths the caller found to exist (granted, §8 below) |
| A6 | R10 "`ssh-keygen -f <existing file>`" has the same problem | `ssh-keygen` that generates or rewrites a key (`-t`, `-f`, `-p`, or no read-only flag) is R10; `-l`, `-y`, `-F`, `-e`, `-i`, `-B` are not |
| A7 | A Fetch file shape in a turn no message of the user's started | class `fetchFile`, R20 among the flags (the Fetch sheet has the same rules and arming as the run sheet, so it shows the tick) |
| A8 | Which here-doc bodies are classified as scripts | a body that reaches a shell (`bash <<EOF`, `sh <<'EOF'`, `cat <<EOF \| sh`, `bash <<< '…'`) is classified as a shell script whatever the quoting; a body given to `cat` or another non-shell with an unquoted delimiter is scanned for `$(…)` and backticks only; with a quoted delimiter it is text. An interpreter's body (`python3 <<EOF`) is R18 and shown, not parsed as shell; not tested |
| A9 | B5 says "decoded text piped into a shell" | also text built with `echo -e '\x..'` or `printf '\x..'` and piped into a shell, and a decoder given to a shell by `<(…)`: all B5 |
| A10 | B6's target list versus its spellings | also `"$DIR/"`, `$HOME/`, `"${HOME}"`, the home folder by its full path (`/Users/alex`, `/Users/alex/`), a variable set from another variable or a substitution, and the program spelled in any case (`RM`, `/BIN/rm`), since the volume is case-insensitive |
| A11 | "the internal disk" without disk facts | `disk0`, `/dev/disk0`, `disk0s*`, `/` and `/System/Volumes/Data` are internal (B6); other disks are R14; only `disk0` is tested |
| A12 | `cd ~ && echo x >> .zshrc` reaches a startup file by a relative path | the run folder is the session's own folder and the text's `cd` is never followed, so by the letter this is only a note. Not tested; the stricter reading (a relative target whose base name is a protected dotfile, or any target after a `cd` to `~`, `$HOME` or `/Users/<user>`, is R5) is recommended |
| A13 | Rows that say "(any)" also match read-only forms | taken literally: `crontab -l`, `launchctl list`, `diskutil list`, `hdiutil info`, `xargs echo`, `osascript` of any text match. `pmset -g` and `mount` alone are not tested |
| A14 | R15 gives no lengths | `sk-`, `ghp_`, `gho_`, `github_pat_`, `xox[abpr]-`, `AKIA` need at least 20 characters after the prefix (`AKIA` 16); a Bearer value needs 40; a JWT has three base64url parts; `*_KEY=`, `*_TOKEN=`, `*_SECRET=`, `PASSWORD=` need a literal value that is not a variable, a substitution or a placeholder |
| A15 | `turnOrigin == .unknown` | by the letter not R20; not tested; a stricter reading (R20 whenever the origin is not `human`) is recommended |
| A16 | "`…` as a path part" | U+2026 is tested (`cd ~/projects/…/x`); three dots are not |
| A17 | Non-ASCII in an unquoted operand (`open ~/Documents/Résumé.pdf`) | allowed and noted, like a quoted one; not tested |
| A18 | A Linux-only program together with a Mac path hint in an SSH session | unclear (a conflict); not tested |
| A19 | What a "token" is for the 2,000 limit | words, operators and redirection operators; a here-doc body line is one token. The vector has 2,500 tokens under any count that includes operators and 1,250 words |
| A20 | Which caption words are a machine claim | "on your Mac", "on this Mac", "locally", "on the server", "on buildbox"; only the first and the fourth are tested |
| A21 | `xargs -0 -I{} rm -rf {}` deletes whatever stdin names | R2 and R18 by the letter, not B6 (`{}` is neither a variable nor a substitution); a stricter reading may block it, which the vector would then flag as a class mismatch |
| A22 | `$(echo rm) -rf ~`, `rm${IFS}-rf${IFS}~` | R11 (risky) by the letter: the program is not known, so B6 cannot match. A stricter reading (block when the words after a built program spell a destroyer) is recommended |
| A23 | `scp buildbox:x ~/Downloads/.zshrc` | the shape matches (§4.2); the name is refused when the fetch starts (Fetch file never repairs a name). Not tested |
| A24 | The fork bomb | a function definition, so B3 by §2.1 (and B6 by the destroyer rule): blocked either way. Not included as a vector |
| A25 | Carriage return | U+000D is Cc and not the newline, so B1 (tested); the session side unifies line endings before an offer is built |
| A26 | Fetch file from a local session | never: §4.2 starts with "only from an SSH session"; the same `scp` text is Not flagged for this Mac with the "not quarantined" note |
| A27 | R22 ("the session has replied since this command") joined the contract after the other red lines were written | a session-side red line: `CommandContext` carries no supersession fact, the classifier never emits R22, and every vector checks that it does not |

## 7. What the vectors cover, and how to run them

812 vectors in 37 groups (`ShellVectors.groups`, each group a `static let` with the rule it covers):
- baseline 23 (plain commands, and rule words that are only arguments);
- red lines R1-R21: 397 (R1 10, R2 33, R3 17, R4 19, R5 27, R6 17, R7 23, R8 15, R9 22, R10 11, R11 18, R12 23,
  R13 9, R14 14, R15 15, R16 14, R17 15, R18 78, R19 5, R20 6, R21 6, the last negatives only, see A5);
- block reasons: 145 (B1 34, B2 14, B3 39, B4 7, B5 13, B6 38);
- language and structure: 123 (accepted syntax 33, spellings and wrappers 47, substitutions 16, here-docs 19,
  pathological inputs 8);
- machines 53 (local, SSH and unknown-place sessions, captions and comments as claims);
- Fetch file 35 (13 shapes that match, 22 near-misses);
- placeholders 16; everyday patterns (group `alex`) 20.
- R22 has no vectors of its own: every vector checks that the classifier never emits it (A27).

Each vector names the session preset (`local`, `ssh`, `unknownPlace`, `taskNotification`), the expected class, the
rules that must be present, absent, or present at least one of, and where it matters the machine, the programs of the
top-level segments and the `FetchFileRequest`. Texts are plain Swift string literals; every invisible or look-alike
character is a `\u{…}` escape, so the source can be read and searched.

Run: `scripts/test.sh --filter ShellVectorTests`. `theVectorTableIsWellFormed` runs at every policy
version (count, unique names, every rule and class covered, nothing but the limit vectors over the size limits);
`everyVectorMatchesTheClassifier` returns early while `CommandClassifier.policyVersion == 0` and otherwise records one
issue per failing vector, as "<name>: class risky, expected blocked; missing B6". A message never holds the text, a
program, a path or a host; look the name up in `ShellVectors.swift`.

When a vector and the implementation disagree, this contract decides; where it is open, §6 says which reading the
vector took, and the vector changes only together with that row.

## 8. Rulings on §6

Binding for the reader; the vectors stay as written unless a ruling below says a stricter reading applies, in which
case the reader implements the stricter reading and the vector author's note on that row is superseded.

| # | Ruling |
| --- | --- |
| A1 | Accepted: blocked, then otherMachine, forServer, needsEditing, unclearMachine, then fetchFile, risky, notFlagged; every flag is still listed. |
| A2, A3, A4, A7, A8, A9, A10, A11, A13, A14, A16-A21, A23-A27 | Accepted as the vectors read them. |
| A5 | Contract added (CommandOffer.swift): `CommandPathFact`, `CommandContext.runFolder`, `CommandContext.pathFacts`, `CommandAssessment.localTargets`. The classifier lists write and copy targets (and `~/.ssh/id_ed25519`, `~/.ssh/id_rsa` when `ssh-keygen` appears) in `localTargets`; the sheet `lstat`s them and assesses again with `pathFacts`. With a fact of `file`, `directory` or `link` for a target, R21 applies ("Replaces <file> (→ <link target>)"); with `missing` or no fact it stays the "Writes <path>" note. |
| A6 | With `pathFacts`: R10 exactly as the rule says (`-f` an existing file, or no `-f` while one of the two default keys exists). Without facts: the vectors' conservative reading (generating or rewriting forms are R10). |
| A12 | The stricter reading: a relative target whose base name is a protected dotfile of R5, or any target after a `cd` to `~`, `$HOME` or `/Users/<user>` in the same text, is R5. |
| A15 | The stricter reading: R20 whenever the turn's origin is not `human`. `unknown` gets the words "Pitbox couldn't tell whether you started this turn". (The session side maps any turn origin other than human, task_notification and peer to `unknown`.) |
| A22 | The stricter reading: when the program is built at run time (R11) and the words after it spell a B6 destroyer (`-r`/`-f` style options with a B6 target), the text is B6. |
