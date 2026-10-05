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
#   RECORD       set to 1 to write per-step geometry artifacts under
#                artifacts/harness-<timestamp>/ (windows, workspaces, verify,
#                debug-windows dumps, and geometry.txt)
#   VERBOSE      set to 1 to print the per-window geometry table every step

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW_COUNT="${WINDOW_COUNT:-3}"
KEEP_WINDOWS="${KEEP_WINDOWS:-0}"
FAILURES=0
STEP=0

ARTIFACTS=""
if [[ "${RECORD:-0}" == "1" ]]; then
  ARTIFACTS="$ROOT/artifacts/harness-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARTIFACTS"
fi
TMP_BEFORE="$(mktemp -t lumina-harness-before)"
TMP_AFTER="$(mktemp -t lumina-harness-after)"
cleanup_tmp() { rm -f "$TMP_BEFORE" "$TMP_AFTER"; }
trap cleanup_tmp EXIT

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

# One line per managed window: id, bundle, space, role, size, position.
geometry_table() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
for w in json.load(sys.stdin).get("windows", []):
    print("id=%-7s %-28s space=%-2d %-7s %4dx%-4d @%d,%d" % (
        w["cgWindowId"], (w.get("bundleId") or "?")[:28], w["space"], w["role"],
        w["w"], w["h"], w["x"], w["y"]))
' 2>/dev/null || true
}

# Per-step artifacts: the geometry a human/agent needs to see a sizing bug
# after the fact. Off unless RECORD=1.
record_step() {
  local label="$1"
  [[ -n "$ARTIFACTS" ]] || return 0
  local n slug
  n="$(printf '%02d' "$STEP")"
  slug="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//')"
  "$LUMINA" list-windows > "$ARTIFACTS/step-$n-$slug.windows.json" 2>/dev/null
  "$LUMINA" list-workspaces > "$ARTIFACTS/step-$n-$slug.workspaces.json" 2>/dev/null
  "$LUMINA" verify > "$ARTIFACTS/step-$n-$slug.verify.json" 2>/dev/null
  local dump
  dump="$("$LUMINA" debug-windows 2>/dev/null)"
  if [[ -n "$dump" && -f "$dump" ]]; then
    cp "$dump" "$ARTIFACTS/step-$n-$slug.debug.json"
  fi
  {
    echo "== step $STEP: $label"
    geometry_table
  } >> "$ARTIFACTS/geometry.txt"
}

# Canonical per-window geometry, sorted, for convergence polling.
geometry_signature() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
rows = []
for w in json.load(sys.stdin).get("windows", []):
    rows.append("%s:%s:%d:%d:%d:%d" % (
        w["cgWindowId"], w["space"], w["x"], w["y"], w["w"], w["h"]))
print("|".join(sorted(rows)))
' 2>/dev/null || true
}

# The layout may need a pass or two to settle after a change (observed
# minimum sizes re-balance a split). Wait until it stops changing.
wait_for_stable_geometry() {
  local deadline=$((SECONDS + 8)) prev="" cur
  while ((SECONDS < deadline)); do
    cur="$(geometry_signature)"
    if [[ -n "$cur" && "$cur" == "$prev" ]]; then return 0; fi
    prev="$cur"
    sleep 0.4
  done
  return 1
}

# Ids whose geometry changed between two list-windows snapshots while staying
# on the same workspace.
geometry_moves() {
  python3 - "$1" "$2" <<'PY'
import json, sys
before = {w["cgWindowId"]: w for w in json.load(open(sys.argv[1]))["windows"]}
after = {w["cgWindowId"]: w for w in json.load(open(sys.argv[2]))["windows"]}
moved = []
for i, w in before.items():
    n = after.get(i)
    if not n or w["space"] != n["space"]:
        continue
    if any(abs(w[k] - n[k]) > 2 for k in ("x", "y", "w", "h")):
        moved.append(i)
print(" ".join(str(i) for i in sorted(moved)))
PY
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
    geometry_table | sed 's/^/      /'
  else
    pass "$label: verify clean"
  fi
  if [[ -n "${TRACKED_IDS:-}" ]]; then
    local missing
    missing="$(missing_ids "$TRACKED_IDS")"
    if [[ -n "$missing" ]]; then
      fail "$label: windows left the model: $missing"
      geometry_table | sed 's/^/      /'
    fi
  fi
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    geometry_table | sed 's/^/      /'
  fi
  record_step "$label"
}

managed_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("windows", [])))' 2>/dev/null || echo 0
}

# Tab apps are excluded: their backing window id legitimately changes on a
# tab switch (the tab section asserts their tile count separately).
window_ids() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
skip = {"com.apple.Terminal", "com.mitchellh.ghostty"}
d = json.load(sys.stdin)
print(" ".join(str(w["cgWindowId"]) for w in d.get("windows", []) if w.get("bundleId") not in skip))
' 2>/dev/null || true
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

new_textedit_id() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
before = {int(x) for x in sys.argv[1].split()}
for w in json.load(sys.stdin).get("windows", []):
    if w["cgWindowId"] not in before and w.get("bundleId") == "com.apple.TextEdit":
        print(w["cgWindowId"])
        break
' "$1" 2>/dev/null || true
}

# `make new document` gives a default-size window that classifies as tiled.
# `open -n` is the permission-free fallback, but TextEdit may restore a saved
# (possibly parked) frame, so prefer the scripted path when allowed. Wait for
# each window to be adopted: rapid document churn makes TextEdit's AX tree
# flaky, and a fixed sleep loses windows.
open_windows() {
  local n="$1"
  for ((i = 0; i < n; i++)); do
    local before id deadline
    before="$(window_ids)"
    if ! osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1; then
      open -n -a TextEdit >/dev/null 2>&1 ||
        { fail "could not launch TextEdit window $((i + 1))"; return 1; }
    fi
    deadline=$((SECONDS + 8))
    id=""
    while ((SECONDS < deadline)); do
      id="$(new_textedit_id "$before")"
      [[ -n "$id" ]] && break
      sleep 0.3
    done
    if [[ -z "$id" ]]; then
      fail "TextEdit window $((i + 1)) was not adopted"
    fi
  done
}

# Close documents before quitting: killing TextEdit makes macOS restore the
# open documents on the next launch, so repeated runs accumulate windows.
close_windows() {
  osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
  osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
  sleep 0.8
  pkill -x TextEdit >/dev/null 2>&1 || true
}

# Start from zero test windows even if a previous run was interrupted.
reset_test_app() {
  close_windows
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

bundle_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for w in d.get("windows", []) if w.get("bundleId") == sys.argv[1]))' "$1" 2>/dev/null || echo 0
}

wait_for_bundle_count() {
  local bundle="$1" want="$2" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(bundle_count "$bundle")" -ge "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

# Terminal.app exposes its tab bar as an AXTabGroup; tabs are created via
# Shell > New Tab > profile and switched by clicking the tab buttons.
terminal_front_id() {
  osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true
}

# Terminal's AppleScript tab count is stale; the AXTabGroup is the truth.
terminal_tab_count() {
  local pid json
  pid="$(ps -axo pid,comm | rg 'Terminal.app/Contents/MacOS/Terminal' | awk '{print $1}' | head -1)"
  [[ -z "$pid" ]] && { echo 0; return; }
  json="$("$LUMINA" debug-ax "$pid" 2>/dev/null)"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
count = 0
def walk(n):
    global count
    if n.get("role") == "AXRadioButton" and n.get("subrole") == "AXTabButton":
        count += 1
    for c in n.get("children", []):
        walk(c)
for w in d.get("windows", []):
    walk(w)
print(count)
' 2>/dev/null || echo 0
}

terminal_new_tab() {
  osascript -e 'tell application "Terminal" to activate' \
    -e 'tell application "System Events" to tell process "Terminal" to click menu item "New Tab" of menu "Shell" of menu bar 1' \
    -e 'delay 0.4' \
    -e 'tell application "System Events" to tell process "Terminal" to click menu item 1 of menu of menu item "New Tab" of menu "Shell" of menu bar 1' 2>&1
}

terminal_switch_tab() {
  osascript -e "tell application \"System Events\" to tell process \"Terminal\" to click radio button $1 of tab group 1 of window 1" 2>&1
}

terminal_close_window() {
  osascript -e "tell application \"Terminal\" to close window id $1 saving no" 2>&1
}

say "Lumina at $LUMINA"
if ! "$LUMINA" status >/dev/null 2>&1; then
  echo "agent is not answering; start Lumina on this Space first." >&2
  exit 2
fi

reset_test_app
sleep 0.5
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
# The first round trip may converge once (observed minimum sizes can
# re-balance a split); the layout must be identical on the next one.
if ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || [[ ! -s "$TMP_BEFORE" ]]; then
  fail "geometry snapshot before the workspace switch failed"
else
  run workspace 2 >/dev/null
  verify "on workspace 2"
  run workspace 1 >/dev/null
  verify "back on workspace 1"
  if ! wait_for_stable_geometry; then
    fail "geometry did not converge after a workspace round trip"
  elif ! "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null || [[ ! -s "$TMP_AFTER" ]]; then
    fail "geometry snapshot after the first workspace switch failed"
  else
    run workspace 2 >/dev/null
    verify "second trip on workspace 2"
    run workspace 1 >/dev/null
    verify "second trip back on workspace 1"
  fi
  if ! wait_for_stable_geometry; then
    fail "geometry did not converge after the second workspace round trip"
  elif ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || [[ ! -s "$TMP_BEFORE" ]]; then
    fail "geometry snapshot after the workspace switch failed"
  elif ! moved="$(geometry_moves "$TMP_AFTER" "$TMP_BEFORE")"; then
    fail "geometry comparison failed (malformed snapshot)"
  elif [[ -n "$moved" ]]; then
    fail "geometry changed across a second workspace round trip: $moved"
    geometry_table | sed 's/^/      /'
  else
    pass "geometry stable across a second workspace round trip"
  fi
fi

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

# Native tabs: Terminal implements each tab as a separate NSWindow. Lumina
# must keep exactly one tile for the app window and swap the backing window
# on a tab switch, never add or lose a tile.
if [[ "${TABS_TEST:-1}" != "0" ]]; then
  say "native tabs: one Terminal tile across tab switches"
  saved_tracked="${TRACKED_IDS:-}"
  TRACKED_IDS=""
  terminal_before="$(bundle_count com.apple.Terminal)"
  created_terminal=0
  if [[ "$terminal_before" -eq 0 ]]; then
    open -n -a Terminal >/dev/null 2>&1
    if wait_for_bundle_count com.apple.Terminal 1; then
      pass "Terminal window adopted"
      created_terminal=1
    else
      fail "Terminal window was not adopted"
    fi
  fi
  expected_terminal="$terminal_before"
  [[ "$expected_terminal" -eq 0 ]] && expected_terminal=1

  terminal_new_tab >/dev/null 2>&1
  sleep 1
  terminal_new_tab >/dev/null 2>&1
  sleep 1
  tabs_created="$(terminal_tab_count)"
  if [[ "$tabs_created" -ge 3 ]]; then
    pass "created $tabs_created Terminal tabs"
  else
    fail "could not create Terminal tabs (count=$tabs_created)"
  fi

  for tab in 2 3 1 2 1; do
    terminal_switch_tab "$tab" >/dev/null 2>&1
    sleep 0.8
    verify "after Terminal tab $tab"
    managed="$(bundle_count com.apple.Terminal)"
    if [[ "$managed" -eq "$expected_terminal" ]]; then
      pass "tab $tab: Terminal still has $managed tile(s)"
    else
      fail "tab $tab: Terminal has $managed managed windows (want $expected_terminal)"
      geometry_table | sed 's/^/      /'
    fi
  done

  if [[ "$created_terminal" -eq 1 ]]; then
    terminal_close_window "$(terminal_front_id)" >/dev/null 2>&1
    sleep 1
    if wait_for_bundle_count com.apple.Terminal 0; then
      pass "Terminal window closed cleanly"
    else
      fail "Terminal window did not close: $(bundle_count com.apple.Terminal) still managed"
    fi
  fi
  TRACKED_IDS="$saved_tracked"
  verify "after native tabs"
fi

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

if [[ -n "$ARTIFACTS" ]]; then
  printf '\nartifacts: %s\n' "$ARTIFACTS"
fi
if [[ $FAILURES -eq 0 ]]; then
  printf '\nharness: PASS (%d verify steps)\n' "$STEP"
  exit 0
fi
printf '\nharness: FAIL (%d failures)\n' "$FAILURES"
exit 1
