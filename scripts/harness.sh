#!/usr/bin/env bash
# End-to-end smoke harness for Lumina on macOS.
#
# Drives the real CLI against the running agent using scriptable TextEdit
# windows, and checks `lumina verify` after every step. An agent can run this
# during development instead of clicking around by hand:
#
#   scripts/harness.sh
#
# Requirements: Lumina is running on this Space, the process running the
# harness has Accessibility and Automation permission (System Settings →
# Privacy & Security), and TextEdit is available. The script opens and
# closes TextEdit documents and opens/kills a test Ghostty instance for the
# native-tabs and new-window sections; do not run it while you are editing a document.
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
#   TABS_TEST    set to 0 to skip the native-tabs (Ghostty) section
#   NEW_WINDOW_TEST set to 0 to skip the Ghostty Cmd-N new-window section
#   BENCH        set to 0 to skip the latency section (default 1)
#   BENCH_COUNT  pings for `lumina bench` (default 50)
#   BENCH_WARMUP warmup pings (default 5)
#   BENCH_MAX_P95_MS  fail when IPC round-trip p95 exceeds this (default 25)
#   BENCH_STRICT set to 1 to fail when a launch takes longer than
#                BENCH_LAUNCH_MAX_MS (default 500) or the menu push takes
#                longer than BENCH_MENU_MAX_MS (default 250)
#   LAUNCH_TEST  set to 0 to skip the cold-launch CG measurement (default 1)
#   FEATURE_TEST set to 0 to skip speculative-tile and hide-until-tiled
#                checks; both temporarily edit the config and restore it
#                (default 1)
#   SHIELD_BOOT_TEST set to 1 to also restart Lumina to check that an app
#                left hidden by a previous agent is revealed at boot
#                (default 0; it quits and restarts the agent)
#   BENCH_COLD_MAX_MS  strict gate for the CG-measured cold launch
#                (default 3000; it includes the app's own launch time)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW_COUNT="${WINDOW_COUNT:-3}"
KEEP_WINDOWS="${KEEP_WINDOWS:-0}"
LUMINA_LOG="${LUMINA_LOG:-$HOME/Library/Logs/Lumina.log}"
CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/lumina/lumina.toml}"
FAILURES=0
STEP=0

ARTIFACTS=""
if [[ "${RECORD:-0}" == "1" ]]; then
  ARTIFACTS="$ROOT/artifacts/harness-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARTIFACTS"
fi
TMP_BEFORE="$(mktemp -t lumina-harness-before)"
TMP_AFTER="$(mktemp -t lumina-harness-after)"
# Independent OS-truth window dumper, compiled once.
CGWINDOWS_BIN=""
if [[ -f "$ROOT/scripts/cgwindows.swift" ]] && command -v swiftc >/dev/null 2>&1; then
  CGWINDOWS_BIN="$(mktemp -t lumina-cgwindows)"
  if ! swiftc -O -o "$CGWINDOWS_BIN" "$ROOT/scripts/cgwindows.swift" >/dev/null 2>&1; then
    CGWINDOWS_BIN=""
  fi
fi
# The feature sections temporarily add top-level config keys; the original
# file is restored on every exit path, including Ctrl-C.
CONFIG_BACKUP=""
cleanup_tmp() {
  rm -f "$TMP_BEFORE" "$TMP_AFTER"
  [[ -n "$CGWINDOWS_BIN" ]] && rm -f "$CGWINDOWS_BIN"
}
cleanup_all() {
  cleanup_tmp
  if declare -F restore_config >/dev/null 2>&1; then restore_config; fi
}
trap cleanup_all EXIT INT TERM

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

# --- Feature-test config surgery -------------------------------------------

backup_config() {
  [[ -n "$CONFIG_BACKUP" ]] && return 0
  [[ -f "$CONFIG_PATH" ]] || return 0
  CONFIG_BACKUP="$(mktemp -t lumina-config-backup)"
  cp "$CONFIG_PATH" "$CONFIG_BACKUP" 2>/dev/null || true
}

# Deleting a key from the file does not reset it on reload: a missing key
# falls back to the value in the running config. So restoring means putting
# the user's file back, explicitly resetting the test keys to their
# defaults, reloading, and reading the user's file again.
restore_config() {
  [[ -n "$CONFIG_BACKUP" ]] || return 0
  cp "$CONFIG_BACKUP" "$CONFIG_PATH" 2>/dev/null || true
  write_config_top_level speculative-tile false
  write_config_top_level hide-until-tiled-apps "[]"
  "$LUMINA" reload >/dev/null 2>&1 || true
  cp "$CONFIG_BACKUP" "$CONFIG_PATH" 2>/dev/null || true
  "$LUMINA" reload >/dev/null 2>&1 || true
  rm -f "$CONFIG_BACKUP"
  CONFIG_BACKUP=""
}

# Force the running agent's test keys back to defaults while preserving the
# file; used at startup in case an interrupted earlier run left them active.
reset_feature_config_in_memory() {
  [[ -f "$CONFIG_PATH" ]] || return 0
  local tmp
  tmp="$(mktemp -t lumina-config-reset)"
  cp "$CONFIG_PATH" "$tmp" 2>/dev/null || true
  write_config_top_level speculative-tile false
  write_config_top_level hide-until-tiled-apps "[]"
  "$LUMINA" reload >/dev/null 2>&1 || true
  cp "$tmp" "$CONFIG_PATH" 2>/dev/null || true
  rm -f "$tmp"
  "$LUMINA" reload >/dev/null 2>&1 || true
}

# Add or replace a top-level key without touching the backup. TOML tables
# own every key after their header, so an appended key would land inside the
# last table; insert before the first table header instead.
write_config_top_level() {
  local key="$1" value="$2"
  python3 - "$CONFIG_PATH" "$key" "$value" <<'PY'
import sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
stripped = [l.strip() for l in lines]
lines = [l for l, s in zip(lines, stripped) if not s.startswith(key + " ")]
idx = next((i for i, s in enumerate(stripped) if s.startswith("[")), len(lines))
lines.insert(idx, "%s = %s" % (key, value))
open(path, "w").write("\n".join(lines) + "\n")
PY
}

set_config_top_level() {
  backup_config
  write_config_top_level "$1" "$2"
}

# --- Cold-launch CG measurement --------------------------------------------

# Open a fresh instance of `app`, then sample the independent CG oracle until
# the new window matches its model tile. Prints one JSON object with the
# first frame the window ever had, when it first appeared, when it reached
# the tile, and whether the very first frame already was the tile.
measure_launch() {
  local app="$1" timeout="${2:-5}"
  [[ -n "$CGWINDOWS_BIN" ]] || return 1
  local before_pids pid deadline t0 out
  before_pids="$(pgrep -x "$app" 2>/dev/null | tr '\n' ' ' || true)"
  t0="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  open -n -a "$app" >/dev/null 2>&1 || return 1
  pid=""
  deadline=$((SECONDS + 4))
  while ((SECONDS < deadline)); do
    for p in $(pgrep -x "$app" 2>/dev/null || true); do
      case " $before_pids " in *" $p "*) continue ;; esac
      pid="$p"
      break
    done
    [[ -n "$pid" ]] && break
    sleep 0.01
  done
  [[ -z "$pid" ]] && return 1
  out=$(python3 - "$CGWINDOWS_BIN" "$LUMINA" "$pid" "$t0" "$timeout" <<'PY' 2>/dev/null || true
import json, subprocess, sys, time

cg_bin, lumina, pid, t0, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
pid_str = str(pid)
deadline = time.time() * 1000 + timeout * 1000
first = None
tiled_at = None
model = None
models = []
i = 0

def close(a, b):
    # CG border bounds include the shadow; the model geometry checks use
    # 12pt.
    return (abs(a["x"] - b["x"]) <= 12 and abs(a["y"] - b["y"]) <= 12
            and abs(a["w"] - b["w"]) <= 12 and abs(a["h"] - b["h"]) <= 12)

while time.time() * 1000 < deadline:
    now = time.time() * 1000
    try:
        rows = json.loads(subprocess.run([cg_bin, pid_str], capture_output=True, timeout=1).stdout)
    except Exception:
        rows = []
    if i % 4 == 0:
        try:
            raw = subprocess.run([lumina, "list-windows"], capture_output=True, timeout=2).stdout
            models = [w for w in json.loads(raw).get("windows", []) if int(w.get("pid", -1)) == pid]
        except Exception:
            models = []
    model_ids = {int(w["cgWindowId"]) for w in models}
    # Prefer a window the model actually tracks: a restored document can sit
    # next to the new one and outsize it.
    tracked = [r for r in rows if int(r["cgWindowId"]) in model_ids] if model_ids else rows
    live = max(tracked or rows, key=lambda r: float(r["w"]) * float(r["h"])) if (tracked or rows) else None
    if live is not None and first is None:
        first = dict(live)
        first["at"] = now
    model = None
    if live is not None:
        model = next((w for w in models if int(w["cgWindowId"]) == int(live["cgWindowId"])), None)
    if live is not None and model is not None and close(live, model):
        tiled_at = now
        break
    i += 1
    time.sleep(0.008)

def rect(r):
    return None if r is None else {"x": r["x"], "y": r["y"], "w": r["w"], "h": r["h"], "onscreen": r.get("onscreen")}

result = {
    "pid": pid,
    "firstMs": None if first is None else round(first["at"] - t0),
    "tiledMs": None if tiled_at is None else round(tiled_at - t0),
    "first": rect(first),
    "model": rect(model),
    "firstIsTile": None if first is None or model is None else close(first, model),
}
print(json.dumps(result))
PY
)
  printf '%s\n' "$out"
}

# Kill a test instance and wait for it to exit. SIGKILL on purpose: SIGTERM
# opens TextEdit's save-confirmation dialog for the untitled test document.
kill_test_instance() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -9 "$pid" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
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

live_windows() {
  [[ -n "$CGWINDOWS_BIN" ]] || return 1
  local pids
  pids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
print(" ".join(str(w["pid"]) for w in json.load(sys.stdin).get("windows", [])))
' 2>/dev/null)"
  if [[ -z "$pids" ]]; then
    echo "[]"
    return 0
  fi
  "$CGWINDOWS_BIN" $pids
}

# Independent live-geometry check against real CG border coordinates, not the
# model: tile/tile overlap, a focused-space tile with no live window (closed
# but still in the model), a real frame far from its model frame, and a tiled
# area that no longer spans the model's tiles. Floater-over-tile is noted but
# allowed by design.
assert_live_geometry() {
  local label="$1"
  [[ -n "$CGWINDOWS_BIN" ]] || return 0
  # A window that refuses its tile floats after the 1.5s refusal hold; give
  # the layout that convergence window before failing.
  local attempt out
  for attempt in 1 2 3; do
    local model live focused
    model="$("$LUMINA" list-windows 2>/dev/null)"
    focused="$("$LUMINA" list-workspaces 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["focused"])' 2>/dev/null)"
    live="$(live_windows 2>/dev/null)" || return 0
    [[ -z "$model" || -z "$focused" || -z "$live" ]] && return 0
    out="$(MODEL="$model" LIVE="$live" FOCUSED="$focused" python3 - <<'PY'
import json, os
model = json.loads(os.environ["MODEL"])
live = json.loads(os.environ["LIVE"])
focused = int(os.environ["FOCUSED"])
live_by_id = {w["cgWindowId"]: w for w in live}
windows = model.get("windows", [])
tiles = [w for w in windows if w.get("role") == "tiled" and w.get("space") == focused]
floats = [w for w in windows if w.get("role") == "floating" and w.get("space") == focused]
problems = []
notes = []

def rect(w):
    return (w["x"], w["y"], w["x"] + w["w"], w["y"] + w["h"])

def overlap(a, b, slop=4):
    ax, ay, ax2, ay2 = rect(a)
    bx, by, bx2, by2 = rect(b)
    iw = min(ax2, bx2) - max(ax, bx)
    ih = min(ay2, by2) - max(ay, by)
    return iw > slop and ih > slop

for w in tiles:
    lw = live_by_id.get(w["cgWindowId"])
    if lw is None:
        problems.append("live-missing-window id=%s %s model=%.0fx%.0f@%.0f,%.0f" % (
            w["cgWindowId"], w.get("bundleId", "?"), w["w"], w["h"], w["x"], w["y"]))
        continue
    if (abs(lw["x"] - w["x"]) > 12 or abs(lw["y"] - w["y"]) > 12
            or abs(lw["w"] - w["w"]) > 12 or abs(lw["h"] - w["h"]) > 12):
        problems.append("live-frame-mismatch id=%s %s live=%.0fx%.0f@%.0f,%.0f model=%.0fx%.0f@%.0f,%.0f" % (
            w["cgWindowId"], w.get("bundleId", "?"),
            lw["w"], lw["h"], lw["x"], lw["y"], w["w"], w["h"], w["x"], w["y"]))

for i in range(len(tiles)):
    for j in range(i + 1, len(tiles)):
        a, b = tiles[i], tiles[j]
        la, lb = live_by_id.get(a["cgWindowId"]), live_by_id.get(b["cgWindowId"])
        if la is None or lb is None:
            continue
        if overlap(la, lb):
            problems.append("live-overlap id=%s %s %.0fx%.0f@%.0f,%.0f vs id=%s %s %.0fx%.0f@%.0f,%.0f" % (
                a["cgWindowId"], a.get("bundleId", "?"), la["w"], la["h"], la["x"], la["y"],
                b["cgWindowId"], b.get("bundleId", "?"), lb["w"], lb["h"], lb["x"], lb["y"]))

for f in floats:
    lf = live_by_id.get(f["cgWindowId"])
    if lf is None:
        continue
    for t in tiles:
        lt = live_by_id.get(t["cgWindowId"])
        if lt is not None and overlap(lf, lt):
            notes.append("floater-over-tile id=%s %s over id=%s %s" % (
                f["cgWindowId"], f.get("bundleId", "?"), t["cgWindowId"], t.get("bundleId", "?")))

def bbox(entries):
    if not entries:
        return None
    xs = [e[0] for e in entries]
    ys = [e[1] for e in entries]
    x2 = [e[2] for e in entries]
    y2 = [e[3] for e in entries]
    return (min(xs), min(ys), max(x2), max(y2))

model_bbox = bbox([rect(w) for w in tiles])
live_bbox = bbox([rect(live_by_id[w["cgWindowId"]]) for w in tiles if w["cgWindowId"] in live_by_id])
if model_bbox and live_bbox and any(abs(a - b) > 6 for a, b in zip(model_bbox, live_bbox)):
    problems.append("live-coverage-hole model=%s live=%s" % (
        ",".join("%.0f" % v for v in model_bbox),
        ",".join("%.0f" % v for v in live_bbox)))

for n in notes:
    print("NOTE " + n)
for p in problems:
    print("PROBLEM " + p)
PY
)"
    if [[ -z "$out" ]]; then
      return 0
    fi
    if printf '%s\n' "$out" | grep -q '^PROBLEM' && [[ "$attempt" -lt 3 ]]; then
      if [[ "$attempt" -eq 1 ]]; then sleep 0.8; else sleep 1.5; fi
      continue
    fi
    printf '%s\n' "$out" | grep '^NOTE' | sed 's/^NOTE/   note:/' || true
    if printf '%s\n' "$out" | grep -q '^PROBLEM'; then
      fail "$label: live geometry issues:"
      printf '%s\n' "$out" | grep '^PROBLEM' | sed 's/^PROBLEM/      /'
      geometry_table | sed 's/^/      /'
    fi
    return 0
  done
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
  assert_live_geometry "$label"
  record_step "$label"
}

managed_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("windows", [])))' 2>/dev/null || echo 0
}

status_visible_count() {
  "$LUMINA" status 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("visibleSpaceCount", 0))' 2>/dev/null || echo 0
}

status_space_count() {
  "$LUMINA" status 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("spaceCount", 10))' 2>/dev/null || echo 10
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

# `open -n` activates TextEdit, so the new window is visible and adopted
# deterministically. `make new document` launches the app hidden, which
# delays adoption until an activation event. Wait for each window: rapid
# document churn makes TextEdit's AX tree flaky.
open_windows() {
  local n="$1"
  for ((i = 0; i < n; i++)); do
    local before id deadline
    before="$(window_ids)"
    open -n -a TextEdit >/dev/null 2>&1 ||
      { fail "could not launch TextEdit window $((i + 1))"; return 1; }
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

wait_for_count_at_most() {
  local want="$1" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(managed_count)" -le "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

# The native-tabs section uses a dedicated Ghostty instance: each tab is a
# separate NSWindow, so every Cmd-T activates a new backing window.
ghostty_pids() {
  ps -axo pid,comm | grep 'Ghostty.app/Contents/MacOS/ghostty' | grep -v grep | awk '{print $1}'
}

pid_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
pid = int(sys.argv[1])
print(sum(1 for w in json.load(sys.stdin).get("windows", []) if w.get("pid") == pid))
' "$1" 2>/dev/null || echo 0
}

wait_for_pid_count() {
  local pid="$1" want="$2" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(pid_count "$pid")" -eq "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

ghostty_new_tab() {
  osascript -e 'tell application "System Events" to keystroke "t" using command down' >/dev/null 2>&1 || true
}

ghostty_next_tab() {
  osascript -e 'tell application "System Events" to keystroke "]" using {command down, shift down}' >/dev/null 2>&1 || true
}

# Cmd-N is a new OS window. Cmd-T (ghostty_new_tab) is a tab in the current one.
ghostty_new_window() {
  osascript -e 'tell application "System Events" to keystroke "n" using command down' >/dev/null 2>&1 || true
}

# Keystrokes go to whichever app is frontmost. Pin that to the test pid and
# return the unix id that actually ended up frontmost.
focus_pid() {
  local pid="$1"
  osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $pid to true" >/dev/null 2>&1 || true
  osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null || true
}

pid_ids() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
ids = [str(w["cgWindowId"]) for w in json.load(sys.stdin).get("windows", []) if w.get("pid") == pid]
print(" ".join(ids))
' "$1" 2>/dev/null || true
}

# On-screen windows of one pid that are not managed tiles, or that cover
# another on-screen window. Empty output is clean. No output when the CG
# oracle is unavailable, so a machine without swiftc still has the model checks.
pid_onscreen_problems() {
  local pid="$1"
  [[ -n "$CGWINDOWS_BIN" ]] || return 0
  local model pids live
  model="$("$LUMINA" list-windows 2>/dev/null)" || return 0
  [[ -n "$model" ]] || return 0
  pids="$(printf '%s' "$model" | python3 -c '
import json, sys
print(" ".join(str(w["pid"]) for w in json.load(sys.stdin).get("windows", [])))
' 2>/dev/null)"
  live="$("$CGWINDOWS_BIN" "$pid" $pids 2>/dev/null)" || return 0
  [[ -n "$live" ]] || return 0
  MODEL="$model" LIVE="$live" PID="$pid" python3 - <<'PY'
import json, os
model = json.loads(os.environ["MODEL"])
live = json.loads(os.environ["LIVE"])
pid = int(os.environ["PID"])
managed = {w["cgWindowId"] for w in model.get("windows", [])}

def big(w):
    return w.get("onscreen") and w.get("w", 0) >= 80 and w.get("h", 0) >= 80

def overlap(a, b, slop=4):
    iw = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
    ih = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
    return iw > slop and ih > slop

ours = [w for w in live if w.get("pid") == pid and big(w)]
others = [w for w in live if w.get("pid") != pid and big(w) and w["cgWindowId"] in managed]
problems = []
for w in ours:
    if w["cgWindowId"] not in managed:
        problems.append("unmanaged-onscreen id=%s %.0fx%.0f@%.0f,%.0f" % (
            w["cgWindowId"], w["w"], w["h"], w["x"], w["y"]))
for i in range(len(ours)):
    for j in range(i + 1, len(ours)):
        a, b = ours[i], ours[j]
        if overlap(a, b):
            problems.append("overlap id=%s %.0fx%.0f@%.0f,%.0f vs id=%s %.0fx%.0f@%.0f,%.0f" % (
                a["cgWindowId"], a["w"], a["h"], a["x"], a["y"],
                b["cgWindowId"], b["w"], b["h"], b["x"], b["y"]))
for w in ours:
    for other in others:
        if overlap(w, other):
            problems.append("covers id=%s pid=%s vs id=%s pid=%s" % (
                w["cgWindowId"], w.get("pid"), other["cgWindowId"], other.get("pid")))
print("\n".join(problems))
PY
}

say "Lumina at $LUMINA"
if ! "$LUMINA" status >/dev/null 2>&1; then
  echo "agent is not answering; start Lumina on this Space first." >&2
  exit 2
fi
# The agent reads the config at start and on reload. Reset the feature-test
# keys in memory and re-read the file so an interrupted earlier run cannot
# leave shield/speculative behavior active for this run.
reset_feature_config_in_memory

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

# Closing one window (app stays running) must reflow the remaining tiles.
# The live-geometry oracle inside verify catches a stale tile/coverage hole.
say "closing one window reflows the rest"
before_ids="$(window_ids)"
open_windows 1
closed_id="$(new_textedit_id "$before_ids")"
close_count="$(managed_count)"
osascript -e 'tell application "TextEdit" to close front window saving no' >/dev/null 2>&1
if wait_for_count_at_most "$((close_count - 1))"; then
  pass "closed window left the model"
else
  fail "closed window still managed: $(managed_count) (was $close_count)"
fi
if [[ -n "$closed_id" ]]; then
  TRACKED_IDS="$(printf '%s' "$TRACKED_IDS" | tr ' ' '\n' | grep -v "^${closed_id}$" | tr '\n' ' ')"
fi
verify "after closing one window"

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

# The menu extra strip shows at least five workspaces and grows only when a
# higher one is used.
say "menu extra workspace count grows with use"
visible_before="$(status_visible_count)"
configured="$(status_space_count)"
if [[ "$visible_before" -ge 5 ]]; then
  pass "strip shows at least 5 workspaces ($visible_before)"
else
  fail "strip shows only $visible_before workspaces (want at least 5)"
fi
target="$configured"
[[ "$target" -gt 7 ]] && target=7
if [[ "$target" -gt 5 ]]; then
  run move-node-to-workspace "$target" >/dev/null
  sleep 1
  visible_used="$(status_visible_count)"
  if [[ "$visible_used" -ge "$target" ]]; then
    pass "strip grew to $visible_used after using workspace $target"
  else
    fail "strip did not grow after using workspace $target: $visible_used"
  fi
  run move-node-to-workspace 1 >/dev/null
  run workspace 1 >/dev/null
  sleep 1
  visible_after="$(status_visible_count)"
  if [[ "$visible_after" -ge 5 && "$visible_after" -le "$visible_used" ]]; then
    pass "strip settled at $visible_after after the window left"
  else
    fail "strip did not settle: $visible_after (was $visible_used)"
  fi
  verify "after workspace count check"
else
  pass "configured space count is $configured; the 5-workspace minimum covers it"
fi

say "reload config"
run reload >/dev/null
verify "after reload"

# Latency: pure IPC round trips (no Accessibility needed) and the agent's
# recorded event-to-frame time. The IPC gate is always on; the frame gate is
# opt-in because it is machine- and app-dependent.
if [[ "${BENCH:-1}" != "0" ]]; then
  say "latency: IPC round trips"
  bench_out="$("$LUMINA" bench --count "${BENCH_COUNT:-50}" --warmup "${BENCH_WARMUP:-5}" --max-p95-ms "${BENCH_MAX_P95_MS:-25}" 2>&1)"
  bench_rc=$?
  printf '%s\n' "$bench_out"
  if [[ $bench_rc -eq 0 ]]; then
    pass "bench p95 within ${BENCH_MAX_P95_MS:-25}ms"
  else
    fail "bench exited $bench_rc"
  fi
  if [[ -n "$ARTIFACTS" ]]; then
    printf '%s\n' "$bench_out" > "$ARTIFACTS/bench.json"
  fi

  say "latency: agent refresh-to-frame"
  # Generate fresh samples with a workspace round trip, then read the p95 the
  # agent recorded for real discovery events.
  "$LUMINA" workspace 2 >/dev/null 2>&1
  "$LUMINA" workspace 1 >/dev/null 2>&1
  sleep 0.5
  frame_out="$("$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
last = s.get("refreshLatencyMs")
p95 = s.get("refreshLatencyP95Ms")
if last is None:
    print("no refresh latency samples yet")
else:
    print("refreshLatency last=%.1fms p95=%.1fms" % (last, p95 if p95 is not None else last))
' 2>/dev/null || true)"
  if [[ -n "$frame_out" ]]; then
    printf '   %s\n' "$frame_out"
  fi
  if [[ -n "$ARTIFACTS" ]]; then
    "$LUMINA" status > "$ARTIFACTS/bench-status.json" 2>/dev/null
  fi

  say "latency: launch adoption"
  # A fresh document in the already-running TextEdit exercises the created
  # path end to end; status carries the agent's event-to-frame time for it.
  launch_before="$(managed_count)"
  if osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1; then
    deadline=$((SECONDS + 5))
    while ((SECONDS < deadline)) && [[ "$(managed_count)" -le "$launch_before" ]]; do sleep 0.1; done
    sleep 0.3
    launch_ms="$("$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = s.get("refreshLatencyMs")
if v is not None:
    print("%.1f" % v)
' 2>/dev/null || true)"
    if [[ -n "$launch_ms" ]]; then
      printf '   refreshLatency last=%sms (created path)\n' "$launch_ms"
      if [[ -n "$ARTIFACTS" ]]; then
        printf '%s\n' "$launch_ms" > "$ARTIFACTS/bench-launch-ms.txt"
      fi
      if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
        launch_max="${BENCH_LAUNCH_MAX_MS:-500}"
        if python3 -c "import sys; sys.exit(0 if float('${launch_ms}') <= float('${launch_max}') else 1)"; then
          pass "launch-to-frame ${launch_ms}ms within ${launch_max}ms"
        else
          fail "launch-to-frame ${launch_ms}ms exceeds ${launch_max}ms"
        fi
      fi
    else
      printf '   no launch latency sample\n'
    fi
    osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null 2>&1
  else
    printf '   TextEdit unavailable; launch latency skipped\n'
  fi

  say "latency: menu push"
  # The extra logs a timestamped line for every pushed snapshot; compare it
  # with the moment the switch command was issued.
  "$LUMINA" workspace 2 >/dev/null 2>&1
  push_before="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  "$LUMINA" workspace 1 >/dev/null 2>&1
  sleep 0.3
  push_line="$(grep 'push space=1 at=' "$LUMINA_LOG" 2>/dev/null | tail -1 || true)"
  push_at="${push_line##*at=}"
  if [[ -n "$push_at" && "$push_at" =~ ^[0-9]+$ ]]; then
    push_delta=$((push_at - push_before))
    if ((push_delta >= 0 && push_delta < 5000)); then
      printf '   menu push=%dms\n' "$push_delta"
      if [[ -n "$ARTIFACTS" ]]; then
        printf '%s\n' "$push_delta" > "$ARTIFACTS/bench-menu-push-ms.txt"
      fi
      if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
        menu_max="${BENCH_MENU_MAX_MS:-250}"
        if ((push_delta <= menu_max)); then
          pass "menu push ${push_delta}ms within ${menu_max}ms"
        else
          fail "menu push ${push_delta}ms exceeds ${menu_max}ms"
        fi
      fi
    else
      printf '   no fresh menu push observed\n'
    fi
  else
    printf '   no menu push line in the agent log\n'
  fi

  if [[ "${LAUNCH_TEST:-1}" != "0" ]]; then
    say "latency: cold-launch CG measurement"
    if [[ -n "$CGWINDOWS_BIN" ]]; then
      cold_json="$(measure_launch TextEdit 8)"
      cold_pid="$(printf '%s' "$cold_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
      cold_tiled="$(printf '%s' "$cold_json" | python3 -c 'import json,sys
try:
    v = json.load(sys.stdin).get("tiledMs")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
      cold_first_tile="$(printf '%s' "$cold_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("firstIsTile"))
except Exception: print("")' 2>/dev/null)"
      if [[ -n "$cold_tiled" ]]; then
        printf '   cold launch pid=%s first=%sms tiled=%sms firstIsTile=%s\n' \
          "$cold_pid" \
          "$(printf '%s' "$cold_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("firstMs"))' 2>/dev/null)" \
          "$cold_tiled" "$cold_first_tile"
        if [[ -n "$ARTIFACTS" ]]; then
          printf '%s\n' "$cold_json" > "$ARTIFACTS/cold-launch.json"
        fi
        if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
          cold_max="${BENCH_COLD_MAX_MS:-3000}"
          if ((cold_tiled <= cold_max)); then
            pass "cold launch tiled in ${cold_tiled}ms within ${cold_max}ms"
          else
            fail "cold launch took ${cold_tiled}ms (limit ${cold_max}ms)"
          fi
        fi
      else
        fail "cold launch never produced a tiled window ($cold_json)"
      fi
      if [[ -n "$cold_pid" ]]; then
        repark_count="$(grep -c "pre-park re-park .* pid=$cold_pid " "$LUMINA_LOG" 2>/dev/null || true)"
        printf '   re-park lines for pid %s: %s (bounded at 3)\n' "$cold_pid" "${repark_count:-0}"
        if (( ${repark_count:-0} > 3 )); then
          fail "re-park looped for pid $cold_pid (${repark_count} attempts)"
        fi
      fi
      kill_test_instance "$cold_pid" >/dev/null 2>&1 || fail "could not stop the cold-launch test instance"
      sleep 0.6
    else
      printf '   cgwindows unavailable; cold-launch CG measurement skipped\n'
    fi
  fi

  if [[ "${FEATURE_TEST:-1}" != "0" && -n "$CGWINDOWS_BIN" && -f "$CONFIG_PATH" ]]; then
    say "launch concealment: speculative tile"
    set_config_top_level speculative-tile true
    "$LUMINA" reload >/dev/null 2>&1
    sleep 0.3
    spec_json="$(measure_launch TextEdit 8)"
    spec_pid="$(printf '%s' "$spec_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
    spec_first_tile="$(printf '%s' "$spec_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("firstIsTile"))
except Exception: print("")' 2>/dev/null)"
    if [[ -n "$ARTIFACTS" ]]; then printf '%s\n' "$spec_json" > "$ARTIFACTS/speculative-tile.json"; fi
    spec_first_ms="$(printf '%s' "$spec_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("firstMs"))
except Exception: print("")' 2>/dev/null)"
    printf '   speculative tile pid=%s first=%sms firstIsTile=%s\n' "$spec_pid" "$spec_first_ms" "$spec_first_tile"
    # The app can paint before the watch detects it, and a fast adoption can
    # tile before any pre-park runs, so the first observed frame is not a
    # sound assertion on its own. Pass when the window was written straight
    # to a predicted tile, or when its first observed frame already was the
    # tile; fail if a corner park was used.
    if [[ -n "$spec_pid" ]] \
      && grep -q "pre-park tile .* pid=$spec_pid " "$LUMINA_LOG" 2>/dev/null; then
      if grep -q "pre-park window .* pid=$spec_pid " "$LUMINA_LOG" 2>/dev/null; then
        fail "speculative tile: a corner park was also used for pid $spec_pid"
      else
        pass "speculative tile: window was written straight to a predicted tile"
      fi
    elif [[ "$spec_first_tile" == "True" ]]; then
      pass "speculative tile: first observed frame already was the tile (adopted before any park)"
    elif [[ -n "$spec_pid" ]]; then
      fail "speculative tile: no 'pre-park tile' line and first frame was not the tile ($spec_json)"
    else
      fail "speculative tile: no measurement ($spec_json)"
    fi
    kill_test_instance "$spec_pid" >/dev/null 2>&1 || true
    restore_config
    sleep 0.6

    say "launch concealment: hide until tiled"
    set_config_top_level hide-until-tiled-apps '["com.apple.TextEdit"]'
    "$LUMINA" reload >/dev/null 2>&1
    sleep 0.3
    shield_json="$(measure_launch TextEdit 8)"
    shield_pid="$(printf '%s' "$shield_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
    shield_tiled="$(printf '%s' "$shield_json" | python3 -c 'import json,sys
try:
    v = json.load(sys.stdin).get("tiledMs")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
    if [[ -n "$ARTIFACTS" ]]; then printf '%s\n' "$shield_json" > "$ARTIFACTS/hide-until-tiled.json"; fi
    if [[ -z "$shield_tiled" ]]; then
      fail "hide-until-tiled: window never reached its tile ($shield_json)"
    else
      pass "hide-until-tiled: window tiled in ${shield_tiled}ms"
    fi
    if [[ -n "$shield_pid" ]]; then
      if grep -q "launch shield hide pid=$shield_pid " "$LUMINA_LOG" 2>/dev/null \
        && grep -q "launch shield reveal pid=$shield_pid reason=tiled" "$LUMINA_LOG" 2>/dev/null; then
        pass "shield hid the app then revealed it after tiling"
      else
        fail "shield log missing hide/reveal(tiled) for pid $shield_pid"
      fi
      sleep 0.4
      shield_visible="$(osascript -e "tell application \"System Events\" to get visible of first process whose unix id is $shield_pid" 2>/dev/null || true)"
      if [[ "$shield_visible" == "true" ]]; then
        pass "shielded app visible after reveal"
      else
        fail "shielded app still not visible (visible=$shield_visible)"
      fi
      kill_test_instance "$shield_pid" >/dev/null 2>&1 || true
    fi
    restore_config
    sleep 0.6
  fi

  if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
    "$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)
created = s.get("createdLatencyP95Ms")
launched = s.get("launchedLatencyP95Ms")
print("created p95=%s launched p95=%s (report only)" % (created, launched))
' 2>/dev/null || true
  fi
fi

# Native tabs: each tab is a separate NSWindow, so every Cmd-T makes a new
# backing window active. Lumina must keep exactly one tile per app window.
# A dedicated Ghostty instance is opened and killed, so the user's session
# and any Terminal windows are untouched, and the pid count is exact.
if [[ "${TABS_TEST:-1}" != "0" ]]; then
  say "native tabs: one Ghostty tile across tab creation and switches"
  saved_tracked="${TRACKED_IDS:-}"
  TRACKED_IDS=""
  pids_before="$(ghostty_pids)"
  open -n -a Ghostty >/dev/null 2>&1
  ghost_pid=""
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    for p in $(ghostty_pids); do
      if ! printf '%s\n' "$pids_before" | grep -qx "$p"; then
        ghost_pid="$p"
        break
      fi
    done
    [[ -n "$ghost_pid" ]] && break
    sleep 0.4
  done
  if [[ -z "$ghost_pid" ]]; then
    fail "could not start a test Ghostty instance"
  else
    if wait_for_pid_count "$ghost_pid" 1; then
      pass "Ghostty window adopted"
    else
      fail "Ghostty window was not adopted"
    fi
    # The cold launch should have been caught by the willLaunch watch (or, if
    # app-driven, the created note). Either is fine; report which.
    if grep -Eq "launch watch (start pid=$ghost_pid reason=willLaunch|sighting pid=$ghost_pid)" "$LUMINA_LOG" 2>/dev/null; then
      pass "cold launch watched from willLaunch"
    else
      printf '   note: no launch-watch line for pid %s (created note handled it)\n' "$ghost_pid"
    fi
    for tab in 1 2 3; do
      ghostty_new_tab
      sleep 1.2
      managed="$(pid_count "$ghost_pid")"
      if [[ "$managed" -eq 1 ]]; then
        pass "after Cmd-T $tab: Ghostty still has 1 tile"
      else
        fail "after Cmd-T $tab: Ghostty has $managed managed windows (want 1)"
        geometry_table | sed 's/^/      /'
      fi
      verify "after Ghostty tab $tab"
    done
    # Tab switching is best effort: the key binding is user-configurable.
    for i in 1 2 3; do
      ghostty_next_tab
      sleep 0.8
      managed="$(pid_count "$ghost_pid")"
      if [[ "$managed" -eq 1 ]]; then
        pass "after tab switch $i: Ghostty still has 1 tile"
      else
        fail "after tab switch $i: Ghostty has $managed managed windows (want 1)"
      fi
    done
    verify "after Ghostty tabs"
    kill "$ghost_pid" >/dev/null 2>&1 || true
    if wait_for_pid_count "$ghost_pid" 0; then
      pass "test Ghostty instance removed"
    else
      fail "test Ghostty instance still managed"
    fi
  fi
  TRACKED_IDS="$saved_tracked"
  verify "after native tabs"
fi

# Cmd-N is a new window, not a tab. Each one joins the tile tree beside the
# windows already on the workspace. Collapsing it into the existing Ghostty
# tile leaves the old window on screen and stacks later windows on top of
# every other app. A dedicated instance is opened and killed, same as tabs.
if [[ "${NEW_WINDOW_TEST:-1}" != "0" ]]; then
  say "Ghostty Cmd-N opens a new tiled window"
  focused="$("$LUMINA" list-workspaces 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["focused"])' 2>/dev/null || true)"
  te_ids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
focused = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("space") == focused and w.get("role") == "tiled" and w.get("bundleId") == "com.apple.TextEdit":
        print(w["cgWindowId"])
' "$focused" 2>/dev/null || true)"
  if [[ -z "$te_ids" ]]; then
    open_windows 1 || true
    te_ids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
focused = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("space") == focused and w.get("role") == "tiled" and w.get("bundleId") == "com.apple.TextEdit":
        print(w["cgWindowId"])
' "$focused" 2>/dev/null || true)"
  fi
  if [[ -z "$te_ids" ]]; then
    fail "no tiled TextEdit on the focused workspace to tile beside"
  else
    if ! wait_for_stable_geometry; then
      fail "geometry did not settle before the Ghostty new-window test"
    fi
    "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || fail "pre-Ghostty snapshot failed"
    pids_before="$(ghostty_pids)"
    open -n -a Ghostty >/dev/null 2>&1
    ghost_pid=""
    deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
      for p in $(ghostty_pids); do
        if ! printf '%s\n' "$pids_before" | grep -qx "$p"; then
          ghost_pid="$p"
          break
        fi
      done
      [[ -n "$ghost_pid" ]] && break
      sleep 0.4
    done
    if [[ -z "$ghost_pid" ]]; then
      fail "could not start a test Ghostty instance for Cmd-N"
    else
      if wait_for_pid_count "$ghost_pid" 1; then
        pass "first Ghostty window adopted"
      else
        fail "first Ghostty window was not adopted (managed $(pid_count "$ghost_pid"))"
      fi
      if ! wait_for_stable_geometry; then
        fail "geometry did not settle after the first Ghostty window"
      fi
      verify "after first Ghostty window for Cmd-N"
      "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null || true
      moved="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
      if [[ -n "$moved" ]]; then
        pass "existing tiles reflowed when Ghostty joined"
      else
        fail "no existing tile moved when the first Ghostty window was adopted"
        geometry_table | sed 's/^/      /'
      fi
      kept_ids="$(pid_ids "$ghost_pid")"
      for n in 1 2; do
        front="$(focus_pid "$ghost_pid")"
        if [[ "$front" != "$ghost_pid" ]]; then
          fail "Cmd-N $n not sent: frontmost pid is ${front:-none}, test pid is $ghost_pid"
          break
        fi
        ghostty_new_window
        want=$((n + 1))
        sleep 0.6
        if wait_for_pid_count "$ghost_pid" "$want"; then
          if ! wait_for_stable_geometry; then
            fail "geometry did not settle after Cmd-N $n"
          fi
          managed="$(pid_count "$ghost_pid")"
          if [[ "$managed" -eq "$want" ]]; then
            pass "after Cmd-N $n: Ghostty has $want managed windows"
          else
            fail "after Cmd-N $n: Ghostty settled at $managed managed windows (want $want)"
            geometry_table | sed 's/^/      /'
          fi
        else
          fail "after Cmd-N $n: Ghostty has $(pid_count "$ghost_pid") managed windows (want $want)"
          geometry_table | sed 's/^/      /'
        fi
        missing=""
        now_ids="$(pid_ids "$ghost_pid")"
        for id in $kept_ids; do
          case " $now_ids " in
            *" $id "*) ;;
            *) missing="$missing $id" ;;
          esac
        done
        if [[ -z "$missing" ]]; then
          pass "after Cmd-N $n: earlier Ghostty windows stayed in the model"
        else
          fail "after Cmd-N $n: Ghostty windows left the model:$missing"
        fi
        problems="$(pid_onscreen_problems "$ghost_pid")"
        if [[ -n "$problems" ]]; then
          fail "after Cmd-N $n: Ghostty windows overlap or sit outside the model"
          printf '%s\n' "$problems" | sed 's/^/      /'
        else
          pass "after Cmd-N $n: on-screen Ghostty windows match their tiles"
        fi
        verify "after Ghostty Cmd-N $n"
        kept_ids="$now_ids"
      done
      "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null || true
      moved="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
      te_moved=""
      for id in $te_ids; do
        case " $moved " in
          *" $id "*) te_moved="$te_moved $id" ;;
        esac
      done
      if [[ -n "$te_moved" ]]; then
        pass "TextEdit still reflowed after Cmd-N:$te_moved"
      else
        # A spiral split of the Ghostty tile does not move every sibling.
        # Falling all the way back to the pre-Ghostty frames means the new
        # windows never joined that tree.
        fail "TextEdit frames match the pre-Ghostty snapshot after Cmd-N (ids: $te_ids)"
        geometry_table | sed 's/^/      /'
      fi
      kill "$ghost_pid" >/dev/null 2>&1 || true
      if wait_for_pid_count "$ghost_pid" 0; then
        pass "Cmd-N test Ghostty instance removed"
      else
        fail "Cmd-N test Ghostty instance still managed"
      fi
      verify "after Ghostty new-window cleanup"
    fi
  fi
fi

# Shield recovery: a crash or force-quit can leave a hide-until-tiled app
# hidden with no in-memory state to reveal it. Boot must unhide it. Off by
# default because it quits and restarts the agent (which recenters windows).
if [[ "${SHIELD_BOOT_TEST:-0}" == "1" && -f "$CONFIG_PATH" ]]; then
  say "launch concealment: hidden app revealed after agent restart"
  set_config_top_level hide-until-tiled-apps '["com.apple.TextEdit"]'
  "$LUMINA" reload >/dev/null 2>&1
  sleep 0.3
  boot_json="$(measure_launch TextEdit 8)"
  boot_pid="$(printf '%s' "$boot_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
  if [[ -z "$boot_pid" ]]; then
    fail "shield boot test: no test instance was launched"
  else
    # Simulate a stranded app: hide it by hand, then restart the agent.
    osascript -e "tell application \"System Events\" to set visible of first process whose unix id is $boot_pid to false" >/dev/null 2>&1 || true
    sleep 0.5
    "$LUMINA" quit >/dev/null 2>&1 || true
    sleep 2.5
    "$LUMINA" start >/dev/null 2>&1 || true
    sleep 6
    boot_visible="$(osascript -e "tell application \"System Events\" to get visible of first process whose unix id is $boot_pid" 2>/dev/null || true)"
    if [[ "$boot_visible" == "true" ]]; then
      pass "boot revealed an app left hidden by the previous agent"
    else
      fail "app still hidden after agent restart (visible=$boot_visible)"
    fi
    kill_test_instance "$boot_pid" >/dev/null 2>&1 || true
  fi
  restore_config
  verify "after shield boot recovery"
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
