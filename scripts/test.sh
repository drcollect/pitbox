#!/bin/bash
# Run the tests (Swift Testing) on a Mac with the Command Line Tools only (no Xcode, no XCTest) or with Xcode.
#   scripts/test.sh                          every test: built once, then each test target in its own process
#   scripts/test.sh --filter PitboxKitTests  one test target, suite or test (any `swift test` arguments)
# One process per target keeps the timing-sensitive suites (real PTYs, scp, WebKit) from starving each other, so
# a --filter naming several targets ('A|B') runs them in ONE process and can fail on timing: run each on its own.
# On a Command-Line-Tools-only Mac the flags below add the framework and rpath locations SwiftPM does not add itself.
# Tests run against a scratch app-support folder (PITBOX_APP_SUPPORT) so they never write into the real
# ~/Library/Application Support/Pitbox or ~/Library/Logs/Pitbox. Set PITBOX_APP_SUPPORT yourself to override.
# PITBOX_SCRATCH=<folder> builds into that folder instead of .build (parallel builds each need their own).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${PITBOX_APP_SUPPORT:-}" ]]; then
  PITBOX_APP_SUPPORT="$(mktemp -d /tmp/pitbox-test.XXXXXX)"
  export PITBOX_APP_SUPPORT
  trap 'rm -rf "$PITBOX_APP_SUPPORT"' EXIT
fi
ARGS=()
if [[ -n "${PITBOX_SCRATCH:-}" ]]; then ARGS+=(--scratch-path "$PITBOX_SCRATCH"); fi
D=/Library/Developer/CommandLineTools/Library/Developer
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* ]]; then
  ARGS+=(-Xswiftc -F"$D/Frameworks" -Xlinker -F"$D/Frameworks"
         -Xlinker -rpath -Xlinker "$D/Frameworks" -Xlinker -rpath -Xlinker "$D/usr/lib")
fi
cd "$ROOT"
if [[ $# -gt 0 ]]; then
  swift test "${ARGS[@]}" "$@"
  exit $?
fi
swift build --build-tests "${ARGS[@]}"
FAILED=()
for dir in "$ROOT"/Tests/*Tests; do
  target="$(basename "$dir")"
  echo "=== $target"
  LOG="$(mktemp "${TMPDIR:-/tmp}/pitbox-test-log.XXXXXX")"
  if swift test --skip-build "${ARGS[@]}" --filter "^$target\\." 2>&1 | tee "$LOG"; then
    # A filter that matched nothing would pass silently: a target must run at least one test.
    /usr/bin/grep -qE 'Test run with [1-9][0-9]* tests?' "$LOG" || FAILED+=("$target (no tests ran)")
  else
    FAILED+=("$target")
  fi
  rm -f "$LOG"
done
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "test.sh: failed: ${FAILED[*]}" >&2
  exit 1
fi
echo "test.sh: every test target passed"
