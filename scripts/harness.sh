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
#   QUIT_TEST    set to 1 to finish by quitting Lumina and checking that every
#                managed window was restored to a usable size (Lumina stays
#                quit afterwards; relaunch it yourself)
#   LUMINA_LOG   agent log path (default ~/Library/Logs/Lumina.log)

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

# Check invariants and that no tracked window silently left the model.
verify() {
  local label="${1:-verify}"
  STEP=$((STEP + 1))
  local out rc
  if ! "$LUMINA" list-windows >/dev/null 2>&1; then
    fail "$label: lumina list-windows failed (agent down?)"
    return
  fi
  out="$("$LUMINA" verify 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$label: verify found issues ($out)"
  else
    pass "$label: verify clean"
  fi
  if [[ -n "${TRACKED_IDS:-}" ]]; then
    local missing
    missing="$(missing_ids "$TRACKED_IDS")"
    if [[ -n "$missing" ]]; then
      fail "$label: windows left the model: $missing"
    fi
  fi
}

managed_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("windows", [])))' 2>/dev/null || echo 0
}

window_ids() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(str(w["cgWindowId"]) for w in d.get("windows", [])))' 2>/dev/null || true
}

count_on_space() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); s=int(sys.argv[1]); print(sum(1 for w in d.get("windows", []) if w.get("space") == s))' "$1" 2>/dev/null || echo 0
}

# Ids that were in the model before but are gone now. Catches the reported
# "opening on a new workspace empties the others" bug directly.
missing_ids() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
current = {w["cgWindowId"] for w in json.load(sys.stdin).get("windows", [])}
expected = {int(x) for x in sys.argv[1].split()}
print(" ".join(str(i) for i in sorted(expected - current)))
' "$1" 2>/dev/null || true
}

# `open -n` needs no Automation permission, unlike osascript-driven TextEdit.
open_windows() {
  local n="$1"
  for ((i = 0; i < n; i++)); do
    open -n -a TextEdit >/dev/null 2>&1 ||
      { fail "could not launch TextEdit window $((i + 1))"; return 1; }
    sleep 0.4
  done
}

# The harness owns every TextEdit instance it launched; the header warns the
# user not to have documents open.
close_windows() {
  pkill -x TextEdit >/dev/null 2>&1 || true
  sleep 0.8
}

wait_for_count() {
  local want="$1" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(managed_count)" -ge "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

wait_for_space_count() {
  local space="$1" want="$2" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(count_on_space "$space")" -ge "$want" ]]; then return 0; fi
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
TRACKED_IDS="$(window_ids)"

# Regression for "swapped to a new workspace and opened something, all the
# other workspaces got emptied". Opening on a fresh workspace must not remove
# a single tracked window from any other workspace.
say "open on a fresh workspace keeps the other workspaces intact"
space1_before="$(count_on_space 1)"
run workspace 2 >/dev/null
verify "on empty workspace 2"
open_windows 1
if wait_for_space_count 2 1; then
  pass "the new window landed on workspace 2"
else
  fail "the new window did not land on workspace 2 (found on another workspace)"
fi
TRACKED_IDS="$TRACKED_IDS $(window_ids)"
if [[ "$(count_on_space 1)" -ge "$space1_before" ]]; then
  pass "workspace 1 kept its $space1_before windows"
else
  fail "workspace 1 lost windows: had $space1_before, now $(count_on_space 1)"
fi
verify "after opening on workspace 2"
run workspace 1 >/dev/null
verify "back on workspace 1"

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

if [[ "${QUIT_TEST:-0}" == "1" ]]; then
  # Quit restore is the other reported failure: windows left parked
  # off-screen or at sliver sizes. The agent logs one restore per managed
  # window; check every target is a usable size, then confirm it exited.
  say "quit restore leaves windows usable (QUIT_TEST=1)"
  log_file="${LUMINA_LOG:-$HOME/Library/Logs/Lumina.log}"
  managed_before="$(managed_count)"
  marker="$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')"
  if [[ -z "$marker" ]]; then
    fail "cannot read agent log at $log_file"
    marker=0
  fi
  "$LUMINA" quit >/dev/null 2>&1 || true
  exited=1
  for _ in $(seq 1 30); do
    if ! pgrep -f lumina-agent >/dev/null 2>&1; then
      exited=0
      break
    fi
    sleep 0.5
  done
  if [[ $exited -ne 0 ]]; then
    fail "lumina-agent did not exit after quit"
  fi
  sleep 1
  new_lines="$(tail -n "+$((marker + 1))" "$log_file" 2>/dev/null || true)"
  restored="$(printf '%s\n' "$new_lines" | grep -c 'quit restore' || true)"
  if [[ "$restored" -ge "$managed_before" ]]; then
    pass "logged $restored restores for $managed_before managed windows"
  else
    fail "only $restored restore logs for $managed_before managed windows"
  fi
  slivers="$(printf '%s\n' "$new_lines" | grep 'quit restore' | grep -Ev 'target=[0-9]{3,}x[0-9]{3,}' | wc -l | tr -d ' ')"
  if [[ "$slivers" == "0" ]]; then
    pass "every restore target is a usable size"
  else
    fail "$slivers restore targets are slivers or tiny"
  fi
  TRACKED_IDS=""
  pkill -x TextEdit >/dev/null 2>&1 || true
else
  if [[ "$KEEP_WINDOWS" != "1" ]]; then
    say "closing test windows"
    TRACKED_IDS=""
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
fi

if [[ $FAILURES -eq 0 ]]; then
  printf '\nharness: PASS (%d verify steps)\n' "$STEP"
  exit 0
fi
printf '\nharness: FAIL (%d failures)\n' "$FAILURES"
exit 1
