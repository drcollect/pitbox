#!/bin/bash
# Scrub check: no private names, addresses or secrets in the repository. Must pass before every push.
#   scripts/scrub-check.sh                 files (tracked, staged and new) + every commit message and author on HEAD
#   scripts/scrub-check.sh --history       also every file in every commit on HEAD
#   scripts/scrub-check.sh --generic-only  only the built-in checks below (for contributors without a denylist)
# Built in: IPv4 addresses, e-mail addresses, Slack team ids, and secret shapes (tokens, keys, private keys).
# The maintainer's denylist (names, hosts, folders) lives OUTSIDE the repo: $PITBOX_SCRUB_DENYLIST, default
# ~/.config/pitbox/scrub-denylist ("label<TAB>flags<TAB>regex", flags i or -; "allow<TAB>-<TAB>regex" exempts hits).
# Exceptions for the built-in checks: scripts/scrub-allow.txt, one "label<TAB>regex<TAB># reason" per line.
# Exit 0: no hits. Exit 1: hits (listed as path:line [label]). Exit 2: setup error.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
GREP=/usr/bin/grep
HISTORY=0; GENERIC_ONLY=0
for a in "$@"; do
  case "$a" in
    --history) HISTORY=1 ;;
    --generic-only) GENERIC_ONLY=1 ;;
    *) echo "scrub: unknown argument $a" >&2; exit 2 ;;
  esac
done
DENY="${PITBOX_SCRUB_DENYLIST:-$HOME/.config/pitbox/scrub-denylist}"
ALLOW="$ROOT/scripts/scrub-allow.txt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pitbox-scrub.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# Patterns: label, flags, regex (one per line, tab-separated).
cat > "$WORK/patterns" <<'PAT'
ipv4	-	(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)
email	-	[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}
slack-team-id	-	(^|[^A-Za-z0-9])T0[0-9A-Z]{7,10}([^A-Za-z0-9]|$)
aws-key	-	AKIA[0-9A-Z]{16}
github-token	-	gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}
api-key	-	sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}
slack-token	-	xox[abprs]-[A-Za-z0-9-]{10,}
private-key	-	-----BEGIN [A-Z ]*PRIVATE KEY-----
jwt	-	eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}
assigned-secret	i	(api[_-]?key|secret|token|passw(or)?d)["']?[[:space:]]*[:=][[:space:]]*["'][A-Za-z0-9/+_=-]{16,}["']
PAT
: > "$WORK/allow"
if [[ -f "$ALLOW" ]]; then
  while IFS=$'\t' read -r label rx reason || [[ -n "$label" ]]; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    if [[ -z "${rx:-}" || "${reason:-}" != \#\ ?* ]]; then echo "scrub: allow line without regex or '# reason': $label" >&2; exit 2; fi
    printf '%s\t%s\n' "$label" "$rx" >> "$WORK/allow"
  done < "$ALLOW"
fi
if [[ $GENERIC_ONLY -eq 0 ]]; then
  if [[ ! -r "$DENY" ]]; then echo "scrub: denylist not found ($DENY); use --generic-only without one" >&2; exit 2; fi
  while IFS=$'\t' read -r label flags rx || [[ -n "$label" ]]; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    if [[ "$label" == allow ]]; then printf '*\t%s\n' "$rx" >> "$WORK/allow"; continue; fi
    printf '%s\t%s\t%s\n' "$label" "$flags" "$rx" >> "$WORK/patterns"
  done < "$DENY"
fi

# Inputs: one text per scanned item. Files are scanned in place; names, commit messages and authors go to files.
# Tracked, staged and new files that exist (a file deleted in the working tree is not scanned; its name still is).
git ls-files --cached --others --exclude-standard > "$WORK/names.txt" || exit 2
: > "$WORK/files"
while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\0' "$f" >> "$WORK/files"; done < "$WORK/names.txt"
if git rev-parse -q --verify HEAD >/dev/null; then
  git log --format='commit %H%nauthor %an <%ae>%ncommitter %cn <%ce>%n%B' HEAD > "$WORK/commits.txt" || exit 2
else
  : > "$WORK/commits.txt"
fi

scan() { # label flags regex -> appends "where [label]" lines to hits; exits 2 if a search fails
  local label="$1" flags="$2" rx="$3" ci="" out="$WORK/raw" st
  [[ "$flags" == *i* ]] && ci="-i"
  : > "$out"
  xargs -0 "$GREP" -a -n -H -E $ci -e "$rx" -- < "$WORK/files" >> "$out" 2>"$WORK/err"; st=$?
  # xargs ends 1 (BSD) or 123 (GNU) when a grep call found nothing or failed; a failure also writes to err.
  if [[ $st -ne 0 && $st -ne 1 && $st -ne 123 ]] || [[ -s "$WORK/err" ]]; then echo "scrub: search failed for [$label]" >&2; cat "$WORK/err" >&2; exit 2; fi
  for f in names commits; do
    "$GREP" -n -E $ci -e "$rx" "$WORK/$f.txt" > "$WORK/raw2"; st=$?
    [[ $st -gt 1 ]] && { echo "scrub: search failed for [$label] in $f" >&2; exit 2; }
    sed "s#^#($f):#" "$WORK/raw2" >> "$out"
  done
  if [[ $HISTORY -eq 1 ]] && git rev-parse -q --verify HEAD >/dev/null; then
    while read -r rev; do
      git grep -a -n -E $ci -e "$rx" "$rev" -- > "$WORK/raw2"; st=$?
      [[ $st -gt 1 ]] && { echo "scrub: history search failed for [$label]" >&2; exit 2; }
      # "rev:path:line:text" -> "path:line:text", so allow lines match as for the working tree
      sed -E 's#^[0-9a-f]{40}:##' "$WORK/raw2" >> "$out"
    done < <(git rev-list HEAD)
  fi
  local hit ok alabel arx
  while IFS= read -r hit; do
    ok=0
    while IFS=$'\t' read -r alabel arx; do
      [[ "$alabel" != "*" && "$alabel" != "$label" ]] && continue
      if printf '%s\n' "$hit" | "$GREP" -q -E -e "$arx"; then ok=1; break; fi
    done < "$WORK/allow"
    [[ $ok -eq 0 ]] && printf '%s [%s]\n' "$(printf '%s' "$hit" | cut -d: -f1-2)" "$label" >> "$WORK/hits"
  done < "$out"
  return 0
}
: > "$WORK/hits"
while IFS=$'\t' read -r label flags rx; do scan "$label" "$flags" "$rx" || exit 2; done < "$WORK/patterns"

n=$(sort -u "$WORK/hits" | wc -l | tr -d ' ')
if [[ "$n" -gt 0 ]]; then
  sort -u "$WORK/hits" | head -200
  echo "scrub: $n hit(s)" >&2
  exit 1
fi
echo "scrub: clean ($(wc -l < "$WORK/names.txt" | tr -d ' ') files, $($GREP -c '^commit ' "$WORK/commits.txt") commits$([[ $GENERIC_ONLY -eq 1 ]] && echo ', generic checks only'))"
