#!/usr/bin/env bash
# Ghostty-only Lumina showcase. Run it from inside Ghostty:
#
#   demo/showcase.sh
#
# The Ghostty that launches the script is tiled and kept. Every other window
# the show opens is a new Ghostty process, and only those are closed.
# Keystrokes (a tab, a new window) are sent only after a spawned Ghostty is
# the frontmost process, so the launching window never receives them.
#
# Each workspace is visited once, and each gesture happens once.
#
#   1. this Ghostty tiles, then one more joins the windows already here
#   2. workspace 2 gets five Ghosttys: focus, one swap, resize, balance,
#      float, and Lumina fullscreen
#   3. one of those windows moves onto the empty workspace 5 and stays
#   4. workspace 4: one tab stays one tile, Cmd-N opens a second, then
#      native fullscreen
#   5. workspace 3 fills to nine Ghosttys, then one more that no longer fits
#      (measured 2026-10-06 on a 1454x907 tile area, 8pt gaps)
#   6. two closes with `lumina close` so the remaining tiles reflow
#   7. close every Ghostty the show opened, and quit Lumina
#
#   FAST=1 demo/showcase.sh    shorten the holds

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUMINA="${LUMINA:-$ROOT/dist/Lumina.app/Contents/MacOS/lumina}"
if [[ ! -x "$LUMINA" ]]; then
  LUMINA="$(command -v lumina 2>/dev/null || true)"
fi
if [[ ! -x "$LUMINA" ]]; then
  echo "cannot find the lumina CLI; set LUMINA=/path/to/lumina" >&2
  exit 1
fi

# Nine is the largest set whose live frames stayed disjoint after Ghostty's
# minimum-size hold. One more overlaps on this display.
CROWD=9

RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
GREEN=$'\033[38;5;46m'; YELLOW=$'\033[38;5;226m'; RED=$'\033[38;5;196m'

step() { printf '%s  >>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$1" "$RESET"; }
warn() { printf '%s  %s%s\n' "$YELLOW" "$1" "$RESET"; }
cmd() { "$LUMINA" "$@" >/dev/null 2>&1 || true; }

# Presentation pauses. FAST=1 keeps the waits that exist so a window can appear.
hold() {
  if [[ "${FAST:-0}" == "1" ]]; then
    sleep 0.25
  else
    sleep "$1"
  fi
}

ghostty_pids() {
  # `ucomm` is the executable name. `comm` is the full path on this machine
  # and also contains "ghostty", so either field is accepted.
  ps -axo pid=,ucomm=,comm= | awk 'tolower($2) == "ghostty" || tolower($0) ~ /ghostty$/ {print $1}'
}

# The shell running this script belongs to one Ghostty. Walk parents so a
# Ghostty that was already open is never recorded as ours to kill.
origin_ghostty_pid() {
  local pid="$$" comm parent
  while [[ "$pid" -gt 1 ]]; do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$comm" == *ghostty* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    parent="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
    [[ -n "$parent" && "$parent" != "$pid" ]] || return 1
    pid="$parent"
  done
  return 1
}

ORIGINAL_PID="$(origin_ghostty_pid || true)"
if [[ -z "$ORIGINAL_PID" ]]; then
  echo "start this show from inside Ghostty; the launching window is the one that stays" >&2
  exit 1
fi

SPAWNED=""
LAST_SPAWNED=""
spawn_ghostty() {
  local before="" pid="" tries=0 p
  before="$(ghostty_pids)"
  open -n -a Ghostty --args --window-save-state=never >/dev/null 2>&1 || true
  while (( tries < 80 )) && [[ -z "$pid" ]]; do
    sleep 0.1
    for p in $(ghostty_pids); do
      printf '%s\n' "$before" | grep -qx "$p" && continue
      [[ "$p" == "$ORIGINAL_PID" ]] && continue
      case " $SPAWNED " in *" $p "*) continue ;; esac
      pid="$p"
      break
    done
    tries=$((tries + 1))
  done
  [[ -z "$pid" ]] && return 1
  printf '%s\n' "$pid"
}

# `spawn_ghostty` is called in a command substitution, which is a subshell.
# Recording the pid there would be discarded, and cleanup would not close it.
record_spawned() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "$ORIGINAL_PID" ]] || return 1
  case " $SPAWNED " in
    *" $pid "*) ;;
    *) SPAWNED="$SPAWNED $pid" ;;
  esac
  LAST_SPAWNED="$pid"
  return 0
}

# Wait until that process has one tiled window on the focused workspace.
wait_tiled() {
  local pid="$1" deadline=$((SECONDS + 8))
  while ((SECONDS < deadline)); do
    if "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
focused = int(sys.argv[2])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("pid") == pid and w.get("space") == focused and w.get("role") == "tiled":
        sys.exit(0)
sys.exit(1)
' "$pid" "$2" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

managed_count() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
print(sum(1 for w in json.load(sys.stdin).get("windows", []) if w.get("pid") == pid))
' "$1" 2>/dev/null || echo 0
}

# Pid of the window Lumina considers focused. Empty when nothing is focused.
focused_pid() {
  local id
  id="$("$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("focusedWindow")
    print("" if v is None else v)
except Exception:
    print("")
' 2>/dev/null || true)"
  [[ -n "$id" ]] || return 0
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
want = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("cgWindowId") == want:
        print(w.get("pid") or "")
        break
' "$id" 2>/dev/null || true
}

# Close the focused window only when it belongs to a Ghostty this show opened.
close_spawned_focused() {
  local pid
  pid="$(focused_pid)"
  [[ -n "$pid" && "$pid" != "$ORIGINAL_PID" ]] || return 1
  case " $SPAWNED " in
    *" $pid "*) cmd close; return 0 ;;
  esac
  return 1
}

# Keys go to the frontmost app. Refuse unless that app is a spawned Ghostty.
keys_to_spawned() {
  local pid="$1" key="$2" mods="$3" front
  [[ "$pid" != "$ORIGINAL_PID" ]] || { warn "refusing keys for the launching Ghostty"; return 1; }
  case " $SPAWNED " in
    *" $pid "*) ;;
    *) warn "refusing keys for Ghostty $pid"; return 1 ;;
  esac
  osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $pid to true" >/dev/null 2>&1 || true
  sleep 0.3
  front="$(osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null || true)"
  if [[ "$front" != "$pid" ]]; then
    warn "skipped keys: frontmost is ${front:-none}, wanted Ghostty $pid"
    return 1
  fi
  osascript -e "tell application \"System Events\" to keystroke \"$key\" using $mods" >/dev/null 2>&1 || true
}

open_on() {
  local space="$1" pid=""
  cmd workspace "$space"
  sleep 0.65
  pid="$(spawn_ghostty || true)"
  record_spawned "$pid" || true
  if [[ -z "$pid" ]]; then
    warn "could not open a Ghostty on workspace $space"
    return 1
  fi
  if wait_tiled "$pid" "$space"; then
    sleep 0.35
    return 0
  fi
  warn "Ghostty $pid did not tile on workspace $space"
  return 1
}

count_spawned_on() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
space = int(sys.argv[1])
pids = set(int(x) for x in sys.argv[2].split())
n = 0
for w in json.load(sys.stdin).get("windows", []):
    if w.get("space") == space and w.get("pid") in pids and w.get("role") == "tiled":
        n += 1
print(n)
' "$1" "$SPAWNED" 2>/dev/null || echo 0
}

START_SPACE=1
cleanup() {
  local p
  if [[ -n "$SPAWNED" ]]; then
    step "closing the Ghostty windows this show opened"
    # shellcheck disable=SC2086
    kill $SPAWNED >/dev/null 2>&1 || true
    sleep 0.8
    for p in $SPAWNED; do
      [[ "$p" == "$ORIGINAL_PID" ]] && continue
      kill -9 "$p" >/dev/null 2>&1 || true
    done
  fi
  if "$LUMINA" status >/dev/null 2>&1; then
    cmd workspace "$START_SPACE"
    sleep 0.7
    step "quitting lumina"
    "$LUMINA" quit >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if ! "$LUMINA" status >/dev/null 2>&1; then
  step "starting lumina"
  "$LUMINA" start >/dev/null 2>&1 || { echo "could not start Lumina" >&2; exit 1; }
  tries=0
  while (( tries < 40 )); do
    "$LUMINA" status >/dev/null 2>&1 && break
    sleep 0.25
    tries=$((tries + 1))
  done
fi
if ! "$LUMINA" status >/dev/null 2>&1; then
  echo "Lumina is not running on this Space" >&2
  exit 1
fi

START_SPACE="$("$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try: print(int(json.load(sys.stdin).get("space") or 1))
except Exception: print(1)
' 2>/dev/null)"
START_SPACE="${START_SPACE:-1}"

if [[ "${FAST:-0}" != "1" ]]; then
  printf '\n%s%s  lumina%s\n' "$BOLD" "$GREEN" "$RESET"
  printf '%s  ghostty, the whole layout%s\n\n' "$DIM" "$RESET"
  sleep 0.8
fi

step "this Ghostty tiles"
tiled=0
tries=0
while (( tries < 40 )); do
  if "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("pid") == pid and w.get("role") == "tiled":
        sys.exit(0)
sys.exit(1)
' "$ORIGINAL_PID" 2>/dev/null; then
    tiled=1
    break
  fi
  sleep 0.25
  tries=$((tries + 1))
done
if (( tiled == 0 )); then
  warn "the launching Ghostty was not tiled; continuing"
fi
hold 0.6

step "a new Ghostty joins the windows already here"
pid="$(spawn_ghostty || true)"
record_spawned "$pid" || true
if [[ -n "$pid" ]]; then
  wait_tiled "$pid" "$START_SPACE" || warn "Ghostty $pid did not tile beside the windows already here"
  hold 1.2
else
  warn "could not open a Ghostty on this workspace"
fi

step "workspace 2"
cmd workspace 2
sleep 0.5
for _ in 1 2 3 4 5; do
  pid="$(spawn_ghostty || true)"
  record_spawned "$pid" || true
  if [[ -n "$pid" ]]; then
    wait_tiled "$pid" 2 || warn "Ghostty $pid did not tile on workspace 2"
    sleep 0.15
  else
    warn "could not open another Ghostty on workspace 2"
  fi
done
have="$(count_spawned_on 2)"
if [[ "$have" != "5" ]]; then
  warn "workspace 2 has $have tiled Ghosttys, wanted 5"
fi
step "focus, then one swap ($have windows)"
hold 0.3
cmd focus right
hold 0.45
cmd focus down
hold 0.45
cmd swap left
hold 0.7

step "resize, then balance"
cmd resize grow
hold 0.7
cmd resize shrink
hold 0.7
cmd balance
hold 0.8

step "float one window, then tile it again"
cmd float-toggle
hold 1.1
cmd float-toggle
hold 0.6

step "Lumina fullscreen, the others parked"
cmd fullscreen lumina
sleep 2.6
cmd fullscreen lumina
sleep 1.2

step "move one window onto the empty workspace"
cmd move-node-to-workspace 5
hold 1.5

step "workspace 4 - a tab, then a new window"
WS4_PID=""
if open_on 4; then
  WS4_PID="$LAST_SPAWNED"
fi
if [[ -n "$WS4_PID" ]]; then
  before="$(managed_count "$WS4_PID")"
  if keys_to_spawned "$WS4_PID" t "command down"; then
    hold 1.0
    after="$(managed_count "$WS4_PID")"
    if [[ "$after" != "$before" ]]; then
      warn "a tab changed Ghostty $WS4_PID from $before windows to $after"
    fi
  fi
  if keys_to_spawned "$WS4_PID" n "command down"; then
    tries=0
    while (( tries < 20 )); do
      [[ "$(managed_count "$WS4_PID")" -gt "$before" ]] && break
      sleep 0.25
      tries=$((tries + 1))
    done
    hold 1.0
    if [[ "$(managed_count "$WS4_PID")" -le "$before" ]]; then
      warn "Cmd-N did not open another window of Ghostty $WS4_PID"
    fi
  fi
else
  warn "no Ghostty on workspace 4 for tabs"
fi

step "native fullscreen"
cmd fullscreen native
sleep 2.6
cmd fullscreen native
sleep 1.2

step "workspace 3 - fill to $CROWD Ghosttys"
cmd workspace 3
sleep 0.45
have="$(count_spawned_on 3)"
tries=0
while (( have < CROWD && tries < CROWD )); do
  tries=$((tries + 1))
  pid="$(spawn_ghostty || true)"
  record_spawned "$pid" || true
  if [[ -z "$pid" ]]; then
    warn "stopped at $have Ghosttys on workspace 3"
    break
  fi
  wait_tiled "$pid" 3 || warn "Ghostty $pid did not tile on workspace 3"
  sleep 0.12
  have="$(count_spawned_on 3)"
done
if [[ "$have" != "$CROWD" ]]; then
  warn "workspace 3 has $have tiled Ghosttys, wanted $CROWD"
fi
step "workspace 3 is holding $have Ghosttys"
hold 1.2

step "one more Ghostty, past what still fits"
pid="$(spawn_ghostty || true)"
record_spawned "$pid" || true
if [[ -n "$pid" ]]; then
  # The live frame is what decides. Give the minimum-size hold time to run.
  sleep 2.4
  hold 1.2
else
  warn "could not open the Ghostty past the maximum"
fi

step "close two so the tiles reflow"
closed=0
while (( closed < 2 )); do
  if close_spawned_focused; then
    closed=$((closed + 1))
    hold 0.8
  else
    warn "stopped reflow closes after $closed windows"
    break
  fi
done

step "done"
# cleanup runs from the EXIT trap: close spawned Ghosttys, then quit Lumina.
