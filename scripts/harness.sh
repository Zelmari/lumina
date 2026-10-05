#!/usr/bin/env bash
# End-to-end smoke harness for Lumina on macOS.
#
# Drives the real CLI against the running agent using scriptable TextEdit
# windows, and checks `lumina verify` after every step. An agent can run this
# during development instead of clicking around by hand:
#
#   scripts/harness.sh
#
# Requirements: Lumina is running on this Space, Terminal has Accessibility
# and Automation permission (System Settings → Privacy & Security), and
# TextEdit is available. The script opens and closes TextEdit documents; do
# not run it while you are editing a document.
#
# Env:
#   LUMINA       path to the CLI (default: bundled app, PATH, then .build/debug)
#   WINDOW_COUNT how many test windows to open (default 3)
#   KEEP_WINDOWS set to 1 to leave the documents open for inspection

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW_COUNT="${WINDOW_COUNT:-3}"
KEEP_WINDOWS="${KEEP_WINDOWS:-0}"
FAILURES=0
STEP=0

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "harness.sh only runs on macOS." >&2
  exit 2
fi

pick_lumina() {
  if [[ -n "${LUMINA:-}" ]]; then echo "$LUMINA"; return; fi
  local bundled="$ROOT/dist/Lumina.app/Contents/MacOS/lumina"
  if [[ -x "$bundled" ]]; then echo "$bundled"; return; fi
  if command -v lumina >/dev/null 2>&1; then command -v lumina; return; fi
  echo "$ROOT/.build/debug/lumina"
}

LUMINA="$(pick_lumina)"
if [[ ! -x "$LUMINA" ]]; then
  echo "cannot find the lumina CLI; set LUMINA=/path/to/lumina" >&2
  exit 2
fi

say()  { printf '\n== %s\n' "$*"; }
pass() { printf '   ok: %s\n' "$*"; }
fail() { printf '   FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# Run a CLI command and print its output. Expected to succeed.
run() {
  local out
  out="$("$LUMINA" "$@" 2>&1)"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "lumina $* exited $rc: $out"
  fi
  printf '%s\n' "$out"
}

# Check invariants. Any issue is a failure with the raw report.
verify() {
  local label="${1:-verify}"
  STEP=$((STEP + 1))
  local out rc
  out="$("$LUMINA" verify 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$label: verify found issues ($out)"
  else
    pass "$label: verify clean"
  fi
}

managed_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("windows", [])))' 2>/dev/null || echo 0
}

open_windows() {
  local n="$1"
  for ((i = 0; i < n; i++)); do
    osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 ||
      { fail "could not create TextEdit document $((i + 1))"; return 1; }
    sleep 0.35
  done
}

close_windows() {
  osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
  sleep 0.6
}

wait_for_count() {
  local want="$1" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(managed_count)" -ge "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

say "Lumina at $LUMINA"
if ! "$LUMINA" status >/dev/null 2>&1; then
  echo "agent is not answering; start Lumina on this Space first." >&2
  exit 2
fi

baseline="$(managed_count)"
say "baseline: $baseline managed windows"
verify "baseline"

say "opening $WINDOW_COUNT TextEdit windows"
open_windows "$WINDOW_COUNT" || exit 2
if wait_for_count $((baseline + WINDOW_COUNT)); then
  pass "all $WINDOW_COUNT windows adopted"
else
  fail "windows were not adopted: still $(managed_count) managed (wanted $((baseline + WINDOW_COUNT)))"
fi
verify "after open"

say "focus movement"
run focus right >/dev/null
verify "after focus right"
run focus left >/dev/null
verify "after focus left"

say "swap"
run swap right >/dev/null
verify "after swap right"
run swap left >/dev/null
verify "after swap left"

say "float toggle"
run float-toggle >/dev/null
verify "after float on"
run float-toggle >/dev/null
verify "after float off"

say "lumina fullscreen"
run fullscreen lumina >/dev/null
verify "in fullscreen"
run fullscreen lumina >/dev/null
verify "after fullscreen exit"

say "resize and balance"
run resize grow >/dev/null
run resize shrink >/dev/null
run balance >/dev/null
verify "after resize/balance"

say "workspace switch with hidden windows"
run workspace 2 >/dev/null
verify "on workspace 2"
run workspace 1 >/dev/null
verify "back on workspace 1"

say "move window to workspace 2 and back"
run move-node-to-workspace 2 >/dev/null
verify "after move to 2"
run workspace 2 >/dev/null
verify "on workspace 2 after move"
run move-node-to-workspace 1 >/dev/null
run workspace 1 >/dev/null
verify "back on workspace 1"

say "reload config"
run reload >/dev/null
verify "after reload"

if [[ "$KEEP_WINDOWS" != "1" ]]; then
  say "closing test windows"
  close_windows
  if wait_for_count "$baseline"; then
    pass "baseline restored"
  else
    fail "windows did not close: $(managed_count) managed (baseline $baseline)"
  fi
  verify "after close"
else
  say "KEEP_WINDOWS=1: leaving documents open"
fi

if [[ $FAILURES -eq 0 ]]; then
  printf '\nharness: PASS (%d verify steps)\n' "$STEP"
  exit 0
fi
printf '\nharness: FAIL (%d failures)\n' "$FAILURES"
exit 1
